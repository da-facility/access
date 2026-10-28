import { useEffect, useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { AlertDialog } from "@astryxdesign/core/AlertDialog";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Selector } from "@astryxdesign/core/Selector";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Plus, Trash2 } from "lucide-react";
import { call } from "../lib/rpc";
import type { Operations } from "../server/console";
import { DialogActions, DialogBody, Mono, Muted, Page, Row, Section, Stack, useAction } from "../lib/ui";

export const Route = createFileRoute("/admin/address-books")({
  loader: () => call("books"),
  component: Books,
});

type Data = Awaited<ReturnType<Operations["books"]>>;
type Book = Data["shared"][number];
type Rule = Book["rules"][number];
const ruleLabels: Record<number, string> = { 1: "Read", 2: "Read and write", 3: "Full control" };

function Books() {
  const data = Route.useLoaderData();
  const act = useAction();
  const [editing, setEditing] = useState<Book | "new" | null>(null);
  const [viewing, setViewing] = useState<{ id: string; name: string } | null>(null);
  const [deleting, setDeleting] = useState<Book | null>(null);
  const subjectName = (r: Rule) =>
    r.type === "everyone" ? "Everyone" : r.type === "group" ? data.groups.find((g) => g.id === r.id)?.name ?? "?" : data.users.find((u) => u.id === r.id)?.name ?? "?";
  return (
    <Page
      title="Address books"
      description="Every user has a personal address book that syncs between their RustDesk clients. Shared address books appear as extra tabs for the people you share them with."
      actions={<Button label="New shared book" icon={<Plus size={16} />} onClick={() => setEditing("new")} />}
    >
      <Section title="Shared">
        {data.shared.length === 0 ? (
          <EmptyState isCompact title="No shared address books" description="Share a list of devices, with saved passwords if you like, with a team." />
        ) : (
          <Table
            density="compact"
            data={data.shared}
            idKey="id"
            columns={[
              {
                key: "name",
                header: "Book",
                width: proportional(1.5),
                renderCell: (b) => (
                  <button type="button" onClick={() => setEditing(b)} style={{ all: "unset", cursor: "pointer", fontWeight: 500 }}>
                    {b.name}
                  </button>
                ),
              },
              { key: "peers", header: "Entries", width: proportional(0.7), renderCell: (b) => <Button label={`${b.peers}`} variant="ghost" size="sm" onClick={() => setViewing(b)} /> },
              {
                key: "rules",
                header: "Shared with",
                width: proportional(4),
                renderCell: (b) =>
                  b.rules.length === 0 ? (
                    <Muted>Nobody yet (RustDesk admins only)</Muted>
                  ) : (
                    <span style={{ display: "inline-flex", gap: 6, flexWrap: "wrap" }}>
                      {b.rules.map((r) => (
                        <Badge key={r.type + r.id} variant={r.rule === 3 ? "purple" : r.rule === 2 ? "blue" : "neutral"} label={`${subjectName(r)} · ${ruleLabels[r.rule]}`} />
                      ))}
                    </span>
                  ),
              },
            ]}
          />
        )}
      </Section>
      <Section title="Personal" description="Created when a user first signs in. Saved passwords and password hashes are never shown here.">
        {data.personal.length === 0 ? (
          <EmptyState isCompact title="No personal books yet" />
        ) : (
          <Table
            density="compact"
            data={data.personal}
            idKey="id"
            columns={[
              { key: "owner", header: "Owner", width: proportional(2), renderCell: (b) => b.owner_name },
              { key: "peers", header: "Entries", width: proportional(1), renderCell: (b) => <Button label={`${b.peers}`} variant="ghost" size="sm" onClick={() => setViewing({ id: b.id, name: `${b.owner_name}'s address book` })} /> },
            ]}
          />
        )}
      </Section>
      {editing && <BookDialog book={editing === "new" ? null : editing} data={data} onClose={() => setEditing(null)} onDelete={(b) => (setEditing(null), setDeleting(b))} />}
      {viewing && <PeersDialog book={viewing} onClose={() => setViewing(null)} />}
      <AlertDialog
        isOpen={!!deleting}
        onOpenChange={(open) => !open && setDeleting(null)}
        title={`Delete ${deleting?.name}?`}
        description="Its entries and saved passwords are deleted for everyone it was shared with."
        actionLabel="Delete book"
        actionVariant="destructive"
        onAction={async () => {
          if (deleting) await act(() => call("books.delete", { id: deleting.id }), "Address book deleted");
          setDeleting(null);
        }}
      />
    </Page>
  );
}

function BookDialog({ book, data, onClose, onDelete }: { book: Book | null; data: Data; onClose: () => void; onDelete: (b: Book) => void }) {
  const act = useAction();
  const [name, setName] = useState(book?.name ?? "");
  const [note, setNote] = useState(book?.note ?? "");
  const [rules, setRules] = useState<Rule[]>(book?.rules ?? []);
  const subjects = [
    { value: "everyone:", label: "Everyone" },
    ...data.groups.map((g) => ({ value: `group:${g.id}`, label: `Group: ${g.name}` })),
    ...data.users.map((u) => ({ value: `user:${u.id}`, label: u.name })),
  ];
  const taken = new Set(rules.map((r) => `${r.type}:${r.id}`));
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={560} purpose="form">
      <DialogHeader title={book ? `Edit ${book.name}` : "New shared address book"} onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        <TextInput label="Name" value={name} onChange={setName} isRequired hasAutoFocus />
        <TextArea label="Note" value={note} onChange={setNote} rows={2} isOptional />
        <Stack gap={8}>
          <strong style={{ fontSize: 13 }}>Shared with</strong>
          {rules.map((r, index) => (
            <Row key={r.type + r.id} wrap={false}>
              <span style={{ flex: 1 }}>{subjects.find((s) => s.value === `${r.type}:${r.id}`)?.label ?? "?"}</span>
              <Selector
                label="Permission"
                isLabelHidden
                width={170}
                options={[1, 2, 3].map((v) => ({ value: String(v), label: ruleLabels[v] }))}
                value={String(r.rule)}
                onChange={(v) => setRules(rules.map((x, i) => (i === index ? { ...x, rule: Number(v) } : x)))}
              />
              <Button label="Remove" isIconOnly variant="ghost" icon={<Trash2 size={16} />} onClick={() => setRules(rules.filter((_, i) => i !== index))} />
            </Row>
          ))}
          <Selector
            label="Add person or group"
            isLabelHidden
            placeholder="Add a person or group…"
            hasSearch
            options={subjects.filter((s) => !taken.has(s.value))}
            value=""
            onChange={(v) => {
              const [type, id] = v.split(":");
              setRules([...rules, { type: type as Rule["type"], id: id ?? "", rule: 1 }]);
            }}
          />
          <Muted>Read: see entries and connect. Read and write or full control: also add, edit, delete and tag entries.</Muted>
        </Stack>
      </DialogBody>
      <DialogActions>
        {book && <Button label="Delete" variant="destructive" onClick={() => onDelete(book)} />}
        <span style={{ flex: 1 }} />
        <Button label="Cancel" variant="ghost" onClick={onClose} />
        <Button
          label="Save"
          clickAction={async () => {
            if (await act(() => call("books.save", { id: book?.id, name, note, rules }), "Address book saved")) onClose();
          }}
        />
      </DialogActions>
    </Dialog>
  );
}

function PeersDialog({ book, onClose }: { book: { id: string; name: string }; onClose: () => void }) {
  const [peers, setPeers] = useState<Awaited<ReturnType<typeof call<"books.peers">>> | null>(null);
  useEffect(() => {
    call("books.peers", { id: book.id }).then(setPeers);
  }, [book.id]);
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={720} purpose="info">
      <DialogHeader title={book.name} onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        {!peers ? (
          <Muted>Loading…</Muted>
        ) : peers.length === 0 ? (
          <EmptyState isCompact title="Empty" description="Entries are added from the RustDesk client." />
        ) : (
          <Table
            density="compact"
            data={peers}
            idKey="id"
            columns={[
              { key: "id", header: "ID", width: proportional(1.2), renderCell: (p) => <Mono>{p.id}</Mono> },
              { key: "name", header: "Name", width: proportional(1.5), renderCell: (p) => p.alias || p.hostname || <Muted>—</Muted> },
              { key: "platform", header: "Platform", width: proportional(1), renderCell: (p) => p.platform || <Muted>—</Muted> },
              { key: "tags", header: "Tags", width: proportional(1.5), renderCell: (p) => p.tags.join(", ") || <Muted>—</Muted> },
              { key: "pw", header: "Password", width: proportional(0.8), renderCell: (p) => (p.hasPassword ? "saved" : <Muted>—</Muted>) },
            ]}
          />
        )}
      </DialogBody>
      <DialogActions>
        <Button label="Close" variant="secondary" onClick={onClose} />
      </DialogActions>
    </Dialog>
  );
}
