//! Probe for the patched hbbs. Usage: kx-probe <host:port> <server public key, base64>
//!
//! `key_exchange`, `get_pk`, `get_rs_pk` and `create_symmetric_key_msg` are copied verbatim from
//! the client (src/common.rs); `legacy_key_exchange` is the same exchange as a client from before
//! versions runs it, which the server must refuse.
use hbb_common::{
    anyhow::{anyhow, Context as _},
    bail,
    bytes::Bytes,
    protobuf::Message as _,
    rendezvous_proto::*,
    sodiumoxide::crypto::{box_, secretbox, sign},
    socket_client::connect_tcp,
    log, timeout, ResultType, Stream,
};

const READ_TIMEOUT: u64 = 18_000;
const CONNECT_TIMEOUT: u64 = 18_000;

fn decode64<T: AsRef<[u8]>>(input: T) -> Result<Vec<u8>, hbb_common::base64::DecodeError> {
    #[allow(deprecated)]
    hbb_common::base64::decode(input)
}
/// The server's key exchange on `conn`. `Ok(true)` once the stream is encrypted. `Ok(false)`
/// when the server sent something else first, nothing parseable, or closed: `secure_tcp`
/// tolerates that for servers from before the exchange, `secure_tcp_required` does not.
async fn key_exchange(conn: &mut Stream, key: &str, log_on_success: bool) -> ResultType<bool> {
    let rs_pk = get_rs_pk(key);
    let Some(rs_pk) = rs_pk else {
        bail!("Handshake failed: invalid public key from rendezvous server");
    };
    match timeout(READ_TIMEOUT, conn.next()).await? {
        Some(Ok(bytes)) => {
            if let Ok(msg_in) = RendezvousMessage::parse_from_bytes(&bytes) {
                match msg_in.union {
                    Some(rendezvous_message::Union::KeyExchange(ex)) => {
                        if ex.keys.len() != 1 {
                            bail!("Handshake failed: invalid key exchange message");
                        }
                        let their_pk_b = sign::verify(&ex.keys[0], &rs_pk)
                            .map_err(|_| anyhow!("Signature mismatch in key exchange"))?;
                        let their_pk_b = get_pk(&their_pk_b)
                            .context("Wrong their public length in key exchange")?;
                        // The signed X25519 high bit marks servers that sign their parameters.
                        // X25519 ignores that bit, so old clients use the key unchanged; keep
                        // the bytes as signed, since the transcript and KxParams carry them so.
                        if their_pk_b[31] & 0x80 != 0 || !ex.signed_params.is_empty() {
                            let params = sign::verify(&ex.signed_params, &rs_pk)
                                .ok()
                                .and_then(|signed| {
                                    let params =
                                        signed.strip_prefix(hbb_common::tcp::KX_PARAMS_DOMAIN)?;
                                    KxParams::parse_from_bytes(params).ok()
                                })
                                .ok_or_else(|| {
                                    anyhow!("Missing or invalid signed key exchange parameters")
                                })?;
                            if params.pk[..] != their_pk_b[..] || params.version != ex.version {
                                bail!("Key exchange version or public key does not match its signature");
                            }
                        }
                        let (asymmetric_value, symmetric_value, key) =
                            create_symmetric_key_msg(their_pk_b);
                        let picked = hbb_common::tcp::kx_version_for(ex.version);
                        let mut msg_out = RendezvousMessage::new();
                        msg_out.set_key_exchange(KeyExchange {
                            keys: vec![asymmetric_value.clone(), symmetric_value],
                            version: picked,
                            ..Default::default()
                        });
                        timeout(CONNECT_TIMEOUT, conn.send(&msg_out)).await??;
                        conn.set_negotiated_key(
                            key,
                            true,
                            &hbb_common::tcp::KxTranscript {
                                initiator_pk: &asymmetric_value,
                                responder_pk: &their_pk_b,
                                advertised: ex.version,
                                picked,
                            },
                        )?;
                        if log_on_success {
                            log::info!("Connection secured");
                        }
                        return Ok(true);
                    }
                    _ => {}
                }
            }
        }
        _ => {}
    }
    Ok(false)
}

#[inline]
fn get_pk(pk: &[u8]) -> Option<[u8; 32]> {
    if pk.len() == 32 {
        let mut tmp = [0u8; 32];
        tmp[..].copy_from_slice(&pk);
        Some(tmp)
    } else {
        None
    }
}

#[inline]
pub fn get_rs_pk(str_base64: &str) -> Option<sign::PublicKey> {
    if let Ok(pk) = decode64(str_base64) {
        get_pk(&pk).map(|x| sign::PublicKey(x))
    } else {
        None
    }
}

pub fn create_symmetric_key_msg(their_pk_b: [u8; 32]) -> (Bytes, Bytes, secretbox::Key) {
    let their_pk_b = box_::PublicKey(their_pk_b);
    let (our_pk_b, out_sk_b) = box_::gen_keypair();
    let key = secretbox::gen_key();
    let nonce = box_::Nonce([0u8; box_::NONCEBYTES]);
    let sealed_key = box_::seal(&key.0, &nonce, &their_pk_b, &out_sk_b);
    (Vec::from(our_pk_b.0).into(), sealed_key.into(), key)
}


/// A client from before versions: takes the offered key as it is and runs version 0.
async fn legacy_key_exchange(conn: &mut Stream, key: &str) -> ResultType<()> {
    let rs_pk = get_rs_pk(key).context("bad key")?;
    let bytes = timeout(READ_TIMEOUT, conn.next()).await?.context("closed")??;
    let Some(rendezvous_message::Union::KeyExchange(ex)) =
        RendezvousMessage::parse_from_bytes(&bytes)?.union
    else {
        bail!("first message is not a key exchange");
    };
    let their_pk_b = sign::verify(&ex.keys[0], &rs_pk).map_err(|_| anyhow!("bad signature"))?;
    let their_pk_b = get_pk(&their_pk_b).context("bad pk")?;
    let (asymmetric_value, symmetric_value, key) = create_symmetric_key_msg(their_pk_b);
    let mut msg_out = RendezvousMessage::new();
    msg_out.set_key_exchange(KeyExchange {
        keys: vec![asymmetric_value, symmetric_value],
        ..Default::default()
    });
    conn.send(&msg_out).await?;
    conn.set_key(key);
    Ok(())
}

/// The first message that is not a key exchange, as the client reads replies.
async fn reply(conn: &mut Stream) -> ResultType<RendezvousMessage> {
    for _ in 0..2 {
        let bytes = conn.next_timeout(5_000).await.context("no reply")??;
        let msg = RendezvousMessage::parse_from_bytes(&bytes)?;
        if !matches!(msg.union, Some(rendezvous_message::Union::KeyExchange(_))) {
            return Ok(msg);
        }
    }
    bail!("only key exchanges")
}

#[derive(Clone, Copy, Debug)]
enum Mode {
    Plain,
    Legacy,
    Current,
}

async fn connect(host: &str, key: &str, mode: Mode) -> ResultType<Stream> {
    let mut conn = connect_tcp(host.to_owned(), CONNECT_TIMEOUT).await?;
    match mode {
        Mode::Plain => {}
        Mode::Legacy => legacy_key_exchange(&mut conn, key).await?,
        Mode::Current => {
            if !key_exchange(&mut conn, key, false).await? {
                bail!("the server did not complete the key exchange");
            }
        }
    }
    if !matches!(mode, Mode::Plain) && !conn.is_secured() {
        bail!("not secured");
    }
    Ok(conn)
}

async fn check(host: &str, key: &str, mode: Mode) -> ResultType<()> {
    // Test NAT: the server answers on the same connection.
    let mut conn = connect(host, key, mode).await?;
    let mut msg = RendezvousMessage::new();
    msg.set_test_nat_request(TestNatRequest {
        serial: 0,
        ..Default::default()
    });
    conn.send(&msg).await?;
    let Some(rendezvous_message::Union::TestNatResponse(nat)) = reply(&mut conn).await?.union
    else {
        bail!("no test nat response");
    };
    println!("{mode:?}: test nat ok, port {}", nat.port);

    // Punch hole: the connection's sink goes through the server's punch map before it answers.
    let mut conn = connect(host, key, mode).await?;
    let mut msg = RendezvousMessage::new();
    msg.set_punch_hole_request(PunchHoleRequest {
        id: "999999999".to_owned(),
        licence_key: key.to_owned(),
        token: "kx-probe".to_owned(),
        conn_type: ConnType::DEFAULT_CONN.into(),
        version: "1.5.0".to_owned(),
        ..Default::default()
    });
    conn.send(&msg).await?;
    let Some(rendezvous_message::Union::PunchHoleResponse(ph)) = reply(&mut conn).await?.union
    else {
        bail!("no punch hole response");
    };
    println!("{mode:?}: punch hole ok, failure {:?}", ph.failure.enum_value());
    Ok(())
}

fn main() -> ResultType<()> {
    hbb_common::tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(run())
}

async fn run() -> ResultType<()> {
    let args: Vec<String> = std::env::args().collect();
    let (host, key) = (&args[1], &args[2]);
    let mut failed = false;
    for mode in [Mode::Plain, Mode::Current] {
        if let Err(err) = check(host, key, mode).await {
            println!("{mode:?}: FAILED: {err}");
            failed = true;
        }
    }
    // Version 0 shares a keystream between the directions; the server refuses it.
    match check(host, key, Mode::Legacy).await {
        Ok(()) => {
            println!("Legacy: FAILED, version 0 accepted");
            failed = true;
        }
        Err(err) => println!("Legacy: refused ({err})"),
    }
    // A wrong signing key must be refused by the client.
    let (wrong, _) = sign::gen_keypair();
    let wrong = hbb_common::base64::encode(wrong.0);
    match connect(host, &wrong, Mode::Current).await {
        Ok(_) => {
            println!("wrong key: FAILED, accepted");
            failed = true;
        }
        Err(err) => println!("wrong key: refused ({err})"),
    }
    if failed {
        std::process::exit(1);
    }
    Ok(())
}
