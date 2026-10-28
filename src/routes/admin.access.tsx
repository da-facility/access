import { useState } from "react";
import { createFileRoute } from "@tanstack/react-router";
import { AlertDialog } from "@astryxdesign/core/AlertDialog";
import { Badge } from "@astryxdesign/core/Badge";
import { Banner } from "@astryxdesign/core/Banner";
import { Button } from "@astryxdesign/core/Button";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { MultiSelector } from "@astryxdesign/core/MultiSelector";
import { Selector } from "@astryxdesign/core/Selector";
import { Switch } from "@astryxdesign/core/Switch";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Plus } from "lucide-react";
import { call } from "../lib/rpc";
import type { Operations } from "../server/console";
import { DialogActions, DialogBody, Muted, Page, Section, useAction } from "../lib/ui";

export const Route = createFileRoute("/admin/access")({
  loader: () => call("access"),
  component: Access,
});

type Data = Awaited<ReturnType<Operations["access"]>>;
type UserGroup = Data["userGroups"][number];
type DeviceGroup = Data["deviceGroups"][number];
const NONE = "__none__";

function Access() {
  const data = Route.useLoaderData();
  const act = useAction();
  const [userGroup, setUserGroup] = useState<UserGroup | "new" | null>(null);
  const [deviceGroup, setDeviceGroup] = useState<DeviceGroup | "new" | null>(null);
  const [deleting, setDeleting] = useState<{ kind: "user" | "device"; id: string; name: string } | null>(null);
  const userName = (id: string) => data.users.find((u) => u.id === id)?.name ?? "?";
  const groupName = (id: string) => data.userGroups.find((g) => g.id === id)?.name ?? "?";

  return (
    <Page
      title="Access"
      description="Who can see and reach which devices. People are put in user groups; devices are put in device groups; a device group is granted to users or user groups."
    >
      <Banner
        status="info"
        title="How this is enforced"
        description="Granted devices show up under Accessible devices in the RustDesk client. The open-source ID server still lets anyone with a device's password connect, so for groups with “Only granted people may connect” this console ends sessions from anyone else a few seconds after they start, using the device's own report of who connected."
      />

      <Section
        title="Device groups"
        description="A device's owner always has access. Everyone listed under “Granted to” does too, and so do RustDesk admins."
        actions={<Button label="New device group" size="sm" icon={<Plus size={16} />} onClick={() => setDeviceGroup("new")} />}
      >
        {data.deviceGroups.length === 0 ? (
          <EmptyState isCompact title="No device groups" description="Create one, then put devices in it from the device's page." />
        ) : (
          <Table
            density="compact"
            data={data.deviceGroups}
            idKey="id"
            columns={[
              {
                key: "name",
                header: "Group",
                width: proportional(1.5),
                renderCell: (g) => (
                  <button type="button" onClick={() => setDeviceGroup(g)} style={{ all: "unset", cursor: "pointer", fontWeight: 500 }}>
                    {g.name}
                  </button>
                ),
              },
              { key: "devices", header: "Devices", width: proportional(0.7), renderCell: (g) => g.devices },
              {
                key: "grants",
                header: "Granted to",
                width: proportional(3),
                renderCell: (g) =>
                  g.grants.length === 0 ? (
                    <Muted>Owners and RustDesk admins only</Muted>
                  ) : (
                    <span style={{ display: "inline-flex", gap: 6, flexWrap: "wrap" }}>
                      {g.grants.map((s) => (
                        <Badge key={s.type + s.id} variant={s.type === "group" ? "blue" : "neutral"} label={s.type === "group" ? groupName(s.id) : userName(s.id)} />
                      ))}
                    </span>
                  ),
              },
              { key: "policy", header: "Policy", width: proportional(1.2), renderCell: (g) => data.strategies.find((s) => s.id === g.strategyId)?.name ?? <Muted>Default</Muted> },
              { key: "restrict", header: "Connections", width: proportional(1.3), renderCell: (g) => (g.restrict ? <Badge variant="warning" label="Granted only" /> : <Muted>Anyone with a password</Muted>) },
            ]}
          />
        )}
      </Section>

      <Section
        title="User groups"
        description="Members see each other under Users in the RustDesk client, and inherit what their groups are granted."
        actions={<Button label="New user group" size="sm" icon={<Plus size={16} />} onClick={() => setUserGroup("new")} />}
      >
        {data.userGroups.length === 0 ? (
          <EmptyState isCompact title="No user groups" />
        ) : (
          <Table
            density="compact"
            data={data.userGroups}
            idKey="id"
            columns={[
              {
                key: "name",
                header: "Group",
                width: proportional(1.5),
                renderCell: (g) => (
                  <button type="button" onClick={() => setUserGroup(g)} style={{ all: "unset", cursor: "pointer", fontWeight: 500 }}>
                    {g.name}
                  </button>
                ),
              },
              { key: "members", header: "Members", width: proportional(4), renderCell: (g) => (g.memberIds.length ? g.memberIds.map(userName).join(", ") : <Muted>nobody</Muted>) },
              { key: "note", header: "Note", width: proportional(2), renderCell: (g) => g.note || <Muted>—</Muted> },
            ]}
          />
        )}
      </Section>

      {userGroup && (
        <UserGroupDialog
          group={userGroup === "new" ? null : userGroup}
          users={data.users}
          onClose={() => setUserGroup(null)}
          onDelete={(g) => {
            setUserGroup(null);
            setDeleting({ kind: "user", id: g.id, name: g.name });
          }}
        />
      )}
      {deviceGroup && (
        <DeviceGroupDialog
          group={deviceGroup === "new" ? null : deviceGroup}
          data={data}
          onClose={() => setDeviceGroup(null)}
          onDelete={(g) => {
            setDeviceGroup(null);
            setDeleting({ kind: "device", id: g.id, name: g.name });
          }}
        />
      )}
      <AlertDialog
        isOpen={!!deleting}
        onOpenChange={(open) => !open && setDeleting(null)}
        title={`Delete ${deleting?.name}?`}
        description={deleting?.kind === "device" ? "Its devices stay, without a group. Grants and the group's policy go away." : "Members stay; they lose what the group was granted."}
        actionLabel="Delete group"
        actionVariant="destructive"
        onAction={async () => {
          if (deleting) await act(() => call(deleting.kind === "device" ? "deviceGroups.delete" : "userGroups.delete", { id: deleting.id }), "Group deleted");
          setDeleting(null);
        }}
      />
    </Page>
  );
}

function UserGroupDialog({ group, users, onClose, onDelete }: { group: UserGroup | null; users: Data["users"]; onClose: () => void; onDelete: (g: UserGroup) => void }) {
  const act = useAction();
  const [name, setName] = useState(group?.name ?? "");
  const [note, setNote] = useState(group?.note ?? "");
  const [members, setMembers] = useState<string[]>(group?.memberIds ?? []);
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={500} purpose="form">
      <DialogHeader title={group ? `Edit ${group.name}` : "New user group"} onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        <TextInput label="Name" value={name} onChange={setName} isRequired hasAutoFocus />
        <MultiSelector label="Members" options={users.map((u) => ({ value: u.id, label: u.name }))} value={members} onChange={setMembers} hasSearch triggerDisplay="badges" placeholder="Nobody" />
        <TextArea label="Note" value={note} onChange={setNote} rows={2} isOptional />
      </DialogBody>
      <DialogActions>
        {group && <Button label="Delete" variant="destructive" onClick={() => onDelete(group)} />}
        <span style={{ flex: 1 }} />
        <Button label="Cancel" variant="ghost" onClick={onClose} />
        <Button
          label="Save"
          clickAction={async () => {
            if (await act(() => call("userGroups.save", { id: group?.id, name, note, memberIds: members }), "Group saved")) onClose();
          }}
        />
      </DialogActions>
    </Dialog>
  );
}

function DeviceGroupDialog({ group, data, onClose, onDelete }: { group: DeviceGroup | null; data: Data; onClose: () => void; onDelete: (g: DeviceGroup) => void }) {
  const act = useAction();
  const [name, setName] = useState(group?.name ?? "");
  const [note, setNote] = useState(group?.note ?? "");
  const [strategyId, setStrategyId] = useState(group?.strategyId ?? NONE);
  const [restrict, setRestrict] = useState(group?.restrict ?? false);
  const [grants, setGrants] = useState<string[]>((group?.grants ?? []).map((g) => `${g.type}:${g.id}`));
  const options = [
    { type: "section" as const, title: "User groups", options: data.userGroups.map((g) => ({ value: `group:${g.id}`, label: g.name })) },
    { type: "section" as const, title: "Users", options: data.users.map((u) => ({ value: `user:${u.id}`, label: u.name })) },
  ].filter((s) => s.options.length > 0);
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={540} purpose="form">
      <DialogHeader title={group ? `Edit ${group.name}` : "New device group"} onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        <TextInput label="Name" value={name} onChange={setName} isRequired hasAutoFocus />
        <MultiSelector
          label="Granted to"
          description="These users, and members of these groups, see the group's devices and may connect to them."
          options={options as never}
          value={grants}
          onChange={setGrants}
          hasSearch
          triggerDisplay="badges"
          placeholder="Owners and RustDesk admins only"
        />
        <Selector
          label="Policy"
          description="Applies to devices in the group that have no policy of their own."
          options={[{ value: NONE, label: "Default policy" }, ...data.strategies.map((s) => ({ value: s.id, label: s.name }))]}
          value={strategyId}
          onChange={setStrategyId}
        />
        <Switch
          label="Only granted people may connect"
          description="Ends sessions, a few seconds in, from anyone not signed in to an account with access. Sessions from a RustDesk client that isn't signed in are always ended."
          value={restrict}
          onChange={setRestrict}
        />
        <TextArea label="Note" value={note} onChange={setNote} rows={2} isOptional />
      </DialogBody>
      <DialogActions>
        {group && <Button label="Delete" variant="destructive" onClick={() => onDelete(group)} />}
        <span style={{ flex: 1 }} />
        <Button label="Cancel" variant="ghost" onClick={onClose} />
        <Button
          label="Save"
          clickAction={async () => {
            const parsed = grants.map((g) => {
              const [type, id] = g.split(":");
              return { type: type as "user" | "group", id };
            });
            if (await act(() => call("deviceGroups.save", { id: group?.id, name, note, strategyId: strategyId === NONE ? null : strategyId, restrict, grants: parsed }), "Device group saved")) onClose();
          }}
        />
      </DialogActions>
    </Dialog>
  );
}
