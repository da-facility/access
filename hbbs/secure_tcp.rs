//! The server's half of the key exchange RustDesk clients run on their TCP connection to hbbs
//! before they send anything secret on it, such as the access token of a signed-in client.
//!
//! Every TCP connection gets an offer first: a fresh X25519 public key, signed with the server
//! key the clients already know. A client that wants an encrypted channel answers with its own
//! public key and a symmetric key sealed to ours; everything after that is encrypted with
//! secretbox, a counter for the nonce, in each direction. A client that does not want one skips
//! the offer and talks in the clear, as it always did.
//!
//! Version 1 derives one key per direction from the sealed key, bound to the handshake; the
//! offer advertises it with the parameters signed. Version 0, the original scheme, uses the
//! sealed key for both directions, so both first messages share a keystream; answers that pick
//! it are refused. RustDesk 1.5 picks version 1; older clients picked 0, and a signed-in one
//! that does is refused here as it timed out before.

use hbb_common::{
    anyhow::anyhow, bail, bytes::Bytes, protobuf::Message as _, rendezvous_proto::*, ResultType,
};
use sodiumoxide::{
    crypto::{box_, generichash, secretbox, sign},
    utils::memzero,
};

/// The newest version spoken here.
pub const VERSION: u32 = 1;
/// Prefix of the signed `KxParams`, so they cannot pass for anything else this key signs.
const PARAMS_DOMAIN: &[u8] = b"rdkx-params";
const SPLIT_CONTEXT: &[u8] = b"rdkx-spl";
const FROM_CLIENT: u8 = 1;
const FROM_SERVER: u8 = 2;

/// What the server keeps of its offer until the client answers.
pub struct Offer {
    sk: box_::SecretKey,
    /// Our public key as it went out, the marker bit included.
    pk: [u8; box_::PUBLICKEYBYTES],
}

impl Offer {
    /// A fresh offer, and the message that carries it.
    pub fn new(server_sk: &sign::SecretKey) -> ResultType<(Self, RendezvousMessage)> {
        let (pk, sk) = box_::gen_keypair();
        let mut pk = pk.0;
        // Tells clients that know versions to require the signed parameters. X25519 ignores
        // the bit, so older clients use the key unchanged.
        pk[31] |= 0x80;
        let params = KxParams {
            pk: Bytes::copy_from_slice(&pk),
            version: VERSION,
            ..Default::default()
        };
        let mut payload = PARAMS_DOMAIN.to_vec();
        payload.extend_from_slice(&params.write_to_bytes()?);
        let mut msg = RendezvousMessage::new();
        msg.set_key_exchange(KeyExchange {
            keys: vec![sign::sign(&pk, server_sk).into()],
            version: VERSION,
            signed_params: sign::sign(&payload, server_sk).into(),
            ..Default::default()
        });
        Ok((Self { sk, pk }, msg))
    }

    /// The ciphers for both directions, from the client's answer.
    pub fn accept(self, reply: &KeyExchange) -> ResultType<(Sealer, Opener)> {
        if reply.keys.len() != 2 {
            bail!("key exchange answer has {} keys", reply.keys.len());
        }
        if reply.version != VERSION {
            bail!("key exchange answer picked version {}", reply.version);
        }
        let their_pk: [u8; box_::PUBLICKEYBYTES] = reply.keys[0][..]
            .try_into()
            .map_err(|_| anyhow!("key exchange answer has a public key of the wrong length"))?;
        let nonce = box_::Nonce([0u8; box_::NONCEBYTES]);
        let mut opened = box_::open(&reply.keys[1], &nonce, &box_::PublicKey(their_pk), &self.sk)
            .map_err(|_| anyhow!("key exchange answer does not open"))?;
        let shared = secretbox::Key::from_slice(&opened);
        memzero(&mut opened);
        let shared =
            shared.ok_or_else(|| anyhow!("key exchange answer has a key of the wrong length"))?;
        let derive = |direction| {
            derive_subkey(&shared, direction, VERSION, reply.version, &their_pk, &self.pk)
        };
        Ok((
            Sealer::new(derive(FROM_SERVER)?),
            Opener::new(derive(FROM_CLIENT)?),
        ))
    }
}

/// The version 1 key for one direction, as hbb_common's `Encrypt::derive_subkey` makes it.
fn derive_subkey(
    shared: &secretbox::Key,
    direction: u8,
    advertised: u32,
    picked: u32,
    client_pk: &[u8],
    server_pk: &[u8],
) -> ResultType<secretbox::Key> {
    let failed = |_| anyhow!("key derivation failed");
    let mut h =
        generichash::State::new(Some(secretbox::KEYBYTES), Some(&shared.0)).map_err(failed)?;
    for part in [
        SPLIT_CONTEXT,
        &[direction],
        &advertised.to_le_bytes(),
        &picked.to_le_bytes(),
        client_pk,
        server_pk,
    ] {
        h.update(part).map_err(failed)?;
    }
    secretbox::Key::from_slice(h.finalize().map_err(failed)?.as_ref())
        .ok_or_else(|| anyhow!("key derivation failed"))
}

/// The client's answer to an offer, if that is what `bytes` is.
pub fn answer(bytes: &[u8]) -> Option<KeyExchange> {
    match RendezvousMessage::parse_from_bytes(bytes).ok()?.union {
        Some(rendezvous_message::Union::KeyExchange(ex)) => Some(ex),
        _ => None,
    }
}

/// Message `n` in a direction is sealed with nonce `n`, counted from 1.
fn nonce(n: u64) -> secretbox::Nonce {
    let mut nonce = secretbox::Nonce([0u8; secretbox::NONCEBYTES]);
    nonce.0[..8].copy_from_slice(&n.to_le_bytes());
    nonce
}

/// Encrypts what the server sends.
pub struct Sealer {
    key: secretbox::Key,
    count: u64,
}

impl Sealer {
    fn new(key: secretbox::Key) -> Self {
        Self { key, count: 0 }
    }

    pub fn seal(&mut self, data: &[u8]) -> Vec<u8> {
        self.count += 1;
        secretbox::seal(data, &nonce(self.count), &self.key)
    }
}

/// Decrypts what the client sends.
pub struct Opener {
    key: secretbox::Key,
    count: u64,
}

impl Opener {
    fn new(key: secretbox::Key) -> Self {
        Self { key, count: 0 }
    }

    pub fn open(&mut self, data: &[u8]) -> ResultType<Vec<u8>> {
        self.count += 1;
        secretbox::open(data, &nonce(self.count), &self.key)
            .map_err(|_| anyhow!("message does not decrypt"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hex(b: &[u8]) -> String {
        b.iter().map(|b| format!("{:02x}", b)).collect()
    }

    /// The client's side of the exchange, as RustDesk 1.5 runs it.
    struct Client {
        answer: KeyExchange,
        key: secretbox::Key,
        server_pk: [u8; 32],
    }

    fn client(offer: &RendezvousMessage, server_pk: &sign::PublicKey, picked: u32) -> Client {
        let Some(rendezvous_message::Union::KeyExchange(ex)) = offer.union.clone() else {
            panic!("not a key exchange");
        };
        assert_eq!(ex.keys.len(), 1);
        let pk: [u8; 32] = sign::verify(&ex.keys[0], server_pk).unwrap()[..]
            .try_into()
            .unwrap();
        let params = sign::verify(&ex.signed_params, server_pk).unwrap();
        let params =
            KxParams::parse_from_bytes(params.strip_prefix(b"rdkx-params").unwrap()).unwrap();
        assert_eq!(params.pk[..], pk[..]);
        assert_eq!(params.version, ex.version);
        let (our_pk, our_sk) = box_::gen_keypair();
        let key = secretbox::gen_key();
        let nonce = box_::Nonce([0u8; box_::NONCEBYTES]);
        let sealed = box_::seal(&key.0, &nonce, &box_::PublicKey(pk), &our_sk);
        let answer = KeyExchange {
            keys: vec![our_pk.0.to_vec().into(), sealed.into()],
            version: picked,
            ..Default::default()
        };
        Client { answer, key, server_pk: pk }
    }

    impl Client {
        /// hbb_common's derivation, written out independently of `derive_subkey`.
        fn subkey(&self, direction: u8) -> secretbox::Key {
            let mut h = generichash::State::new(Some(32), Some(&self.key.0)).unwrap();
            for part in [
                b"rdkx-spl".as_slice(),
                &[direction],
                &1u32.to_le_bytes(),
                &1u32.to_le_bytes(),
                &self.answer.keys[0][..],
                &self.server_pk,
            ] {
                h.update(part).unwrap();
            }
            secretbox::Key::from_slice(h.finalize().unwrap().as_ref()).unwrap()
        }
    }

    #[test]
    fn offer_is_signed_and_marked() {
        let (server_pk, server_sk) = sign::gen_keypair();
        let (offer, msg) = Offer::new(&server_sk).unwrap();
        let c = client(&msg, &server_pk, 1);
        assert_eq!(c.server_pk, offer.pk);
        assert_ne!(c.server_pk[31] & 0x80, 0);
    }

    #[test]
    fn version_1_matches_the_client() {
        let (server_pk, server_sk) = sign::gen_keypair();
        let (offer, msg) = Offer::new(&server_sk).unwrap();
        let c = client(&msg, &server_pk, 1);
        let (mut sealer, mut opener) = offer.accept(&c.answer).unwrap();
        let from_client = secretbox::seal(b"token", &nonce(1), &c.subkey(1));
        assert_eq!(opener.open(&from_client).unwrap(), b"token");
        let from_server = sealer.seal(b"reply");
        assert_eq!(secretbox::open(&from_server, &nonce(1), &c.subkey(2)).unwrap(), b"reply");
        // The directions do not share a key, nor use the sealed one.
        assert!(secretbox::open(&from_server, &nonce(1), &c.subkey(1)).is_err());
        assert!(secretbox::open(&from_server, &nonce(1), &c.key).is_err());
    }

    #[test]
    fn version_0_is_refused() {
        let (server_pk, server_sk) = sign::gen_keypair();
        let (offer, msg) = Offer::new(&server_sk).unwrap();
        assert!(offer.accept(&client(&msg, &server_pk, 0).answer).is_err());
    }

    /// The vectors hbb_common pins for its derivation and its frames (client = initiator).
    #[test]
    fn wire_vectors() {
        let shared = secretbox::Key([0x11u8; 32]);
        let derive = |direction, advertised| {
            hex(&derive_subkey(&shared, direction, advertised, 1, &[0x22; 32], &[0x33; 32])
                .unwrap()
                .0)
        };
        assert_eq!(
            derive(FROM_CLIENT, 1),
            "c189ec6e1935c0751cfc85a0f075405cae507d7925bb19687caf56cbb54e0ecf"
        );
        assert_eq!(
            derive(FROM_SERVER, 1),
            "8a62648e9195cb10ea900c0a24d2a166c1e982347a2dc6833c3e756bf5715d36"
        );
        assert_eq!(
            derive(FROM_CLIENT, 3),
            "25b0778ae600f9731c7fa457d1cc5d40071b0aa3d34c90b53e1d5344b0e7123a"
        );
        assert_eq!(
            derive(FROM_SERVER, 3),
            "5bbde0ac6a708d4cd1ff807125d79cb6030bde62f7a66b6cc1a79e31bd657756"
        );
        assert_eq!(
            hex(&Sealer::new(shared).seal(b"hello")),
            "3b768f827fdcc4af555b9e42533be6611e2c333481"
        );
    }

    #[test]
    fn replays_and_tampering_fail() {
        let (server_pk, server_sk) = sign::gen_keypair();
        let (offer, msg) = Offer::new(&server_sk).unwrap();
        let c = client(&msg, &server_pk, 1);
        let (_, mut opener) = offer.accept(&c.answer).unwrap();
        let first = secretbox::seal(b"one", &nonce(1), &c.subkey(1));
        assert_eq!(opener.open(&first).unwrap(), b"one");
        assert!(opener.open(&first).is_err(), "a replay must not open");
        let mut third = secretbox::seal(b"three", &nonce(3), &c.subkey(1));
        third[0] ^= 1;
        assert!(opener.open(&third).is_err(), "a tampered message must not open");
        assert!(opener.open(&[0u8]).is_err(), "a short frame must not pass as plain");
    }

    #[test]
    fn malformed_answers_are_refused() {
        let (server_pk, server_sk) = sign::gen_keypair();
        let mutations: [fn(&mut KeyExchange); 6] = [
            |a| a.keys.truncate(1),
            |a| a.version = 2,
            |a| a.keys[0] = Bytes::from_static(&[1u8; 31]),
            |a| a.keys[0] = Bytes::from_static(&[0u8; 32]),
            |a| {
                let mut sealed = a.keys[1].to_vec();
                sealed[0] ^= 1;
                a.keys[1] = sealed.into();
            },
            |a| a.keys[1] = Bytes::from_static(&[0u8; 5]),
        ];
        for mutate in mutations {
            let (offer, msg) = Offer::new(&server_sk).unwrap();
            let mut answer = client(&msg, &server_pk, 1).answer;
            mutate(&mut answer);
            assert!(offer.accept(&answer).is_err());
        }
    }
}
