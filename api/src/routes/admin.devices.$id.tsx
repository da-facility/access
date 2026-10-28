import { useState } from "react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { AlertDialog } from "@astryxdesign/core/AlertDialog";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { MetadataList, MetadataListItem } from "@astryxdesign/core/MetadataList";
import { Selector } from "@astryxdesign/core/Selector";
import { Switch } from "@astryxdesign/core/Switch";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { ArrowLeft } from "lucide-react";
import { describeValue, policyOption } from "../policy-catalog";
import { categoryLabel, sourceLabel } from "../lib/labels";
import { call } from "../lib/rpc";
import { Ago, Grid, Mono, Muted, Online, Page, Row, Section, Stack, useAction } from "../lib/ui";

export const Route = createFileRoute("/admin/devices/$id")({
  loader: ({ params }) => call("devices.get", { id: params.id }),
  component: DevicePage,
});

const NONE = "__none__";

function DevicePage() {
  const { device, users, deviceGroups, strategies } = Route.useLoaderData();
  const act = useAction();
  const navigate = useNavigate();
  const [alias, setAlias] = useState(device.alias);
  const [note, setNote] = useState(device.note);
  const [forgetting, setForgetting] = useState(false);
  const policyRows = Object.entries(device.policy.options).map(([key, value]) => ({ key, value }));
  const update = (patch: Record<string, unknown>, message: string) => act(() => call("devices.update", { id: device.id, ...patch }), message);

  return (
    <Page
      title={device.alias || device.hostname || device.id}
      description={
        <Row gap={10}>
          <Online online={device.online} />
          <span>
            ID <Mono>{device.id}</Mono>
          </span>
          {device.disabled && <Badge variant="error" label="Incoming sessions blocked" />}
        </Row>
      }
      actions={
        <>
          <Button label="All devices" variant="ghost" icon={<ArrowLeft size={16} />} href="/admin/devices" />
          <Button label="Remove" variant="destructive" onClick={() => setForgetting(true)} />
        </>
      }
    >
      <Grid min={320}>
        <Card padding={4}>
          <MetadataList columns="single" title="System">
            <MetadataListItem label="Hostname">{device.hostname || "—"}</MetadataListItem>
            <MetadataListItem label="OS user">{device.username || "—"}</MetadataListItem>
            <MetadataListItem label="System">{device.os || "—"}</MetadataListItem>
            <MetadataListItem label="CPU">{device.sysinfo.cpu || "—"}</MetadataListItem>
            <MetadataListItem label="Memory">{device.sysinfo.memory || "—"}</MetadataListItem>
            <MetadataListItem label="RustDesk">{device.version || "—"}</MetadataListItem>
            <MetadataListItem label="Last IP">{device.ip || "—"}</MetadataListItem>
            <MetadataListItem label="First seen">
              <Ago at={device.firstSeen} />
            </MetadataListItem>
            <MetadataListItem label="Last seen">{device.online ? "now" : <Ago at={device.lastSeen} />}</MetadataListItem>
            <MetadataListItem label="Signed in as">
              {device.signedIn.length ? device.signedIn.map((s) => s.name).join(", ") : <Muted>no account</Muted>}
            </MetadataListItem>
          </MetadataList>
        </Card>
        <Card padding={4}>
          <Stack gap={14}>
            <TextInput label="Display name" description="Shown in this console instead of the hostname." value={alias} onChange={setAlias} />
            <TextArea label="Note" value={note} onChange={setNote} rows={2} />
            <Row>
              <Button
                label="Save name and note"
                variant="secondary"
                size="sm"
                isDisabled={alias === device.alias && note === device.note}
                clickAction={() => update({ alias, note }, "Saved").then(() => undefined)}
              />
            </Row>
            <Selector
              label="Owner"
              description="The owner always sees this device under Accessible devices in their RustDesk client."
              options={[{ value: NONE, label: "No owner" }, ...users.map((u) => ({ value: u.id, label: u.name }))]}
              value={device.ownerId ?? NONE}
              hasSearch
              onChange={(v) => update({ ownerId: v === NONE ? null : v }, "Owner changed")}
            />
            <Selector
              label="Device group"
              description="Groups decide who else can see and reach the device (Access) and can carry a policy."
              options={[{ value: NONE, label: "No group" }, ...deviceGroups.map((g) => ({ value: g.id, label: g.name }))]}
              value={device.groupId ?? NONE}
              onChange={(v) => update({ groupId: v === NONE ? null : v }, "Group changed")}
            />
            <Selector
              label="Policy override"
              description="Leave on “Inherit” to use the group's policy, or the default one."
              options={[{ value: NONE, label: "Inherit" }, ...strategies.map((s) => ({ value: s.id, label: s.name }))]}
              value={device.strategyId ?? NONE}
              onChange={(v) => update({ strategyId: v === NONE ? null : v }, "Policy changed")}
            />
            <Switch
              label="Block incoming sessions"
              description="Ends every session on this device within seconds of it starting, until switched off."
              value={device.disabled}
              onChange={(disabled) => update({ disabled }, disabled ? "Incoming sessions blocked" : "Incoming sessions allowed")}
            />
          </Stack>
        </Card>
      </Grid>

      <Section
        title="Effective policy"
        description={
          <>
            {sourceLabel(device.policy.source.kind, device.policy.source.groupName)}
            {device.policy.source.strategy ? (
              <>
                {" · "}
                <Link to="/admin/policies" search={{ device: device.id }}>
                  {device.policy.source.strategy.name}
                </Link>
              </>
            ) : null}
            {" · "}
            {device.policy.version === device.reportedPolicy ? "Applied by the device" : "Waiting for the device to apply it"}
          </>
        }
      >
        {policyRows.length === 0 ? (
          <EmptyState isCompact title="Nothing is pushed to this device" description="It keeps whatever its user set locally." />
        ) : (
          <Table
            density="compact"
            data={policyRows}
            idKey="key"
            columns={[
              { key: "label", header: "Setting", width: proportional(2), renderCell: (r) => policyOption(r.key)?.label ?? <Mono>{r.key}</Mono> },
              { key: "value", header: "Value", width: proportional(2), renderCell: (r) => describeValue(policyOption(r.key), r.value) },
              { key: "key", header: "Key", width: proportional(2), renderCell: (r) => <Mono>{r.key}</Mono> },
            ]}
          />
        )}
      </Section>

      <Section title="Sessions" description="Incoming sessions this device reported, and outgoing ones it made to other devices here.">
        {device.connections.length === 0 ? (
          <EmptyState isCompact title="No sessions recorded" />
        ) : (
          <Table
            density="compact"
            data={device.connections}
            idKey="guid"
            columns={[
              {
                key: "direction",
                header: "",
                width: proportional(0.8),
                renderCell: (c) => (c.deviceId === device.id ? <Badge variant="info" label="Incoming" /> : <Badge variant="neutral" label="Outgoing" />),
              },
              {
                key: "peer",
                header: "Other side",
                width: proportional(2),
                renderCell: (c) =>
                  c.deviceId === device.id ? (
                    c.peerId ? (
                      <span>
                        {c.peerName || c.peerId} <Muted>{c.peerUser ? `(${c.peerUser})` : c.ip}</Muted>
                      </span>
                    ) : (
                      <Muted>{c.ip || "unknown"}</Muted>
                    )
                  ) : (
                    <Link to="/admin/devices/$id" params={{ id: c.deviceId }}>
                      {c.deviceName}
                    </Link>
                  ),
              },
              { key: "type", header: "Kind", width: proportional(1.2), renderCell: (c) => c.type || <Muted>not accepted</Muted> },
              { key: "auth", header: "Accepted by", width: proportional(1.4), renderCell: (c) => c.auth || <Muted>—</Muted> },
              { key: "started", header: "Started", width: proportional(1), renderCell: (c) => <Ago at={c.startedAt} /> },
              {
                key: "end",
                header: "",
                width: proportional(1.2),
                renderCell: (c) =>
                  c.blocked ? (
                    <Badge variant="error" label="Blocked" />
                  ) : c.live && c.deviceId === device.id ? (
                    <Button label="End session" size="sm" variant="secondary" clickAction={() => act(() => call("devices.disconnect", { id: device.id, connId: c.connId }), "The session ends within a few seconds").then(() => undefined)} />
                  ) : c.endedAt ? (
                    <Muted>{Math.max(1, Math.round((c.endedAt - c.startedAt) / 60))} min</Muted>
                  ) : null,
              },
            ]}
          />
        )}
      </Section>

      <Section title="Events">
        {device.events.length === 0 ? (
          <EmptyState isCompact title="No events" />
        ) : (
          <Table
            density="compact"
            data={device.events}
            idKey="seq"
            columns={[
              { key: "category", header: "Kind", width: proportional(1), renderCell: (e) => <Badge variant={e.category === "alarm" ? "error" : "neutral"} label={categoryLabel(e.category)} /> },
              { key: "summary", header: "What happened", width: proportional(4), renderCell: (e) => e.summary },
              { key: "at", header: "When", width: proportional(1), renderCell: (e) => <Ago at={e.at} /> },
            ]}
          />
        )}
      </Section>

      <AlertDialog
        isOpen={forgetting}
        onOpenChange={setForgetting}
        title="Remove this device?"
        description="Its owner, group and policy assignment are dropped. If the client is still running with this API server, it registers again as a new device on its next check-in."
        actionLabel="Remove device"
        actionVariant="destructive"
        onAction={async () => {
          await act(() => call("devices.forget", { id: device.id }), "Device removed");
          await navigate({ to: "/admin/devices" });
        }}
      />
    </Page>
  );
}
