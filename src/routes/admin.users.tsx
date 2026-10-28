import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { AlertDialog } from "@astryxdesign/core/AlertDialog";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { MoreMenu } from "@astryxdesign/core/MoreMenu";
import { MultiSelector } from "@astryxdesign/core/MultiSelector";
import { Switch } from "@astryxdesign/core/Switch";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Plus, Users as UsersIcon } from "lucide-react";
import { call } from "../lib/rpc";
import type { Operations } from "../server/console";
import { Ago, DialogActions, DialogBody, Muted, Page, useAction } from "../lib/ui";

export const Route = createFileRoute("/admin/users")({
  loader: () => call("users.list"),
  component: Users,
});

type User = Awaited<ReturnType<Operations["users.list"]>>["users"][number];

function Users() {
  const { users, groups } = Route.useLoaderData();
  const act = useAction();
  const [editing, setEditing] = useState<User | "new" | null>(null);
  const [password, setPassword] = useState<User | null>(null);
  const [deleting, setDeleting] = useState<User | null>(null);
  return (
    <Page
      title="Users"
      description="Accounts people sign in with inside the RustDesk app (Settings → Account). Signing in syncs their address book and lists the devices they may reach. This console itself uses SSO."
      actions={<Button label="New user" icon={<Plus size={16} />} onClick={() => setEditing("new")} />}
    >
      {users.length === 0 ? (
        <EmptyState icon={<UsersIcon size={28} />} title="No users yet" description="Create an account, then sign in with it in the RustDesk client." actions={<Button label="New user" onClick={() => setEditing("new")} />} />
      ) : (
        <Table
          density="compact"
          hasHover
          data={users}
          idKey="id"
          columns={[
            {
              key: "name",
              header: "User",
              width: proportional(2),
              renderCell: (u) => (
                <div style={{ display: "flex", flexDirection: "column" }}>
                  <button type="button" onClick={() => setEditing(u)} style={{ all: "unset", cursor: "pointer", fontWeight: 500 }}>
                    {u.displayName || u.name}
                  </button>
                  <Muted>
                    {u.name}
                    {u.email ? ` · ${u.email}` : ""}
                  </Muted>
                </div>
              ),
            },
            {
              key: "role",
              header: "Role",
              width: proportional(1.2),
              renderCell: (u) => (
                <span style={{ display: "inline-flex", gap: 6 }}>
                  {u.isAdmin && <Badge variant="purple" label="RustDesk admin" />}
                  {!u.active && <Badge variant="error" label="Disabled" />}
                  {!u.isAdmin && u.active && <Muted>Member</Muted>}
                </span>
              ),
            },
            { key: "groups", header: "Groups", width: proportional(1.6), renderCell: (u) => u.groups || <Muted>—</Muted> },
            { key: "devices", header: "Owns", width: proportional(0.8), renderCell: (u) => `${u.devices} device${u.devices === 1 ? "" : "s"}` },
            { key: "sessions", header: "Signed in on", width: proportional(1), renderCell: (u) => (u.sessions ? `${u.sessions} client${u.sessions === 1 ? "" : "s"}` : <Muted>nowhere</Muted>) },
            { key: "last", header: "Last sign-in", width: proportional(1), renderCell: (u) => <Ago at={u.lastLoginAt} /> },
            {
              key: "menu",
              header: "",
              width: { type: "pixel", value: 56 },
              renderCell: (u) => (
                <MoreMenu
                  label={`Actions for ${u.name}`}
                  items={[
                    { id: "edit", label: "Edit", onClick: () => setEditing(u) },
                    { id: "password", label: "Set password", onClick: () => setPassword(u) },
                    { id: "signout", label: "Sign out everywhere", onClick: () => act(() => call("users.signOut", { id: u.id }), `${u.name} signed out`) },
                    { type: "divider" },
                    { id: "delete", label: "Delete", onClick: () => setDeleting(u) },
                  ]}
                />
              ),
            },
          ]}
        />
      )}
      {editing && <UserDialog user={editing === "new" ? null : editing} groups={groups} onClose={() => setEditing(null)} />}
      {password && <PasswordDialog user={password} onClose={() => setPassword(null)} />}
      <AlertDialog
        isOpen={!!deleting}
        onOpenChange={(open) => !open && setDeleting(null)}
        title={`Delete ${deleting?.name}?`}
        description="Their personal address book and KVM list are deleted and they are signed out of every client. Devices they own lose their owner."
        actionLabel="Delete user"
        actionVariant="destructive"
        onAction={async () => {
          if (deleting) await act(() => call("users.delete", { id: deleting.id }), "User deleted");
          setDeleting(null);
        }}
      />
    </Page>
  );
}

function UserDialog({ user, groups, onClose }: { user: User | null; groups: { id: string; name: string }[]; onClose: () => void }) {
  const act = useAction();
  const [name, setName] = useState(user?.name ?? "");
  const [password, setPassword] = useState("");
  const [displayName, setDisplayName] = useState(user?.displayName ?? "");
  const [email, setEmail] = useState(user?.email ?? "");
  const [note, setNote] = useState(user?.note ?? "");
  const [isAdmin, setIsAdmin] = useState(user?.isAdmin ?? false);
  const [active, setActive] = useState(user?.active ?? true);
  const [groupIds, setGroupIds] = useState<string[]>(user?.groupIds ?? []);
  const save = async () => {
    const done = user
      ? await act(() => call("users.update", { id: user.id, displayName, email, note, isAdmin, active, groupIds }), "User saved")
      : await act(() => call("users.create", { name, password, displayName, email, note, isAdmin, groupIds }), "User created");
    if (done) onClose();
  };
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={520} purpose="form">
      <DialogHeader title={user ? `Edit ${user.name}` : "New user"} onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        {!user && (
          <>
            <TextInput label="Username" description="3–64 lowercase letters, numbers, dots, underscores or hyphens. Used to sign in." value={name} onChange={setName} isRequired hasAutoFocus />
            <TextInput label="Password" type="password" description="At least 12 characters." value={password} onChange={setPassword} isRequired />
          </>
        )}
        <TextInput label="Display name" value={displayName} onChange={setDisplayName} isOptional />
        <TextInput label="Email" type="email" value={email} onChange={setEmail} isOptional />
        <MultiSelector label="Groups" options={groups.map((g) => ({ value: g.id, label: g.name }))} value={groupIds} onChange={setGroupIds} triggerDisplay="badges" placeholder="No groups" />
        <TextArea label="Note" value={note} onChange={setNote} rows={2} isOptional />
        <Switch label="RustDesk admin" description="Sees every device and user in the RustDesk client and has full control of every shared address book. Does not grant access to this console." value={isAdmin} onChange={setIsAdmin} />
        {user && <Switch label="Active" description="Disabled accounts cannot sign in and are signed out now." value={active} onChange={setActive} />}
      </DialogBody>
      <DialogActions>
        <Button label="Cancel" variant="ghost" onClick={onClose} />
        <Button label={user ? "Save" : "Create user"} clickAction={save} />
      </DialogActions>
    </Dialog>
  );
}

function PasswordDialog({ user, onClose }: { user: User; onClose: () => void }) {
  const act = useAction();
  const [password, setPassword] = useState("");
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={440} purpose="form">
      <DialogHeader title={`Set a password for ${user.name}`} onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        <TextInput label="New password" type="password" description="At least 12 characters. They are signed out of every client." value={password} onChange={setPassword} hasAutoFocus />
      </DialogBody>
      <DialogActions>
        <Button label="Cancel" variant="ghost" onClick={onClose} />
        <Button
          label="Set password"
          clickAction={async () => {
            if (await act(() => call("users.password", { id: user.id, password }), "Password set")) onClose();
          }}
        />
      </DialogActions>
    </Dialog>
  );
}
