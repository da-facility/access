import { createFileRoute, Link } from "@tanstack/react-router";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Switch } from "@astryxdesign/core/Switch";
import { Table, proportional } from "@astryxdesign/core/Table";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Copy } from "lucide-react";
import { toast } from "@da-facility/ui";
import { call } from "../lib/rpc";
import { Ago, Grid, Mono, Muted, Page, Row, Section, Stack, Stat, useAction } from "../lib/ui";
import { categoryLabel } from "../lib/labels";

export const Route = createFileRoute("/admin/")({
  loader: () => call("overview"),
  component: Overview,
});

function Copyable({ label, value }: { label: string; value: string }) {
  return (
    <Row gap={10} wrap={false}>
      <span style={{ width: 110, flexShrink: 0, color: "var(--color-text-secondary)", fontSize: 13 }}>{label}</span>
      <Mono>{value || "—"}</Mono>
      {value && (
        <Button
          label={`Copy ${label}`}
          isIconOnly
          icon={<Copy size={14} />}
          variant="ghost"
          size="sm"
          onClick={() => navigator.clipboard.writeText(value).then(() => toast.success(`${label} copied`))}
        />
      )}
    </Row>
  );
}

function Overview() {
  const data = Route.useLoaderData();
  const act = useAction();
  const { counts, server } = data;
  return (
    <Page title="Overview" description="Your self-hosted RustDesk: the ID and relay server, plus this console as its API server.">
      <Grid min={170}>
        <Stat label="Devices" value={counts.devices} hint={`${counts.online} online now`} />
        <Stat label="Users" value={counts.users} />
        <Stat label="Live sessions" value={counts.activeSessions} />
        <Stat label="Alarms, last 24 h" value={counts.alarms24h} />
        <Stat label="Policies" value={counts.policies} />
      </Grid>

      <Section
        title="Client settings"
        description="Set these in each RustDesk client under Settings → Network → ID/Relay server. Without the API server, a client can connect but won't sign in, sync, report or receive policies. iOS hides the relay field; it isn't needed there."
      >
        <Card padding={4}>
          <Row gap={24}>
            <div style={{ flex: "1 1 420px", minWidth: 0 }}>
              <Stack gap={8}>
                <Copyable label="ID server" value={server.idServer} />
                <Copyable label="Relay server" value={server.relayServer} />
                <Copyable label="API server" value={server.apiServer} />
                <Copyable label="Key" value={server.key} />
                <Copyable label="All at once" value={data.share} />
                <Muted>Copy “All at once”, then press the paste button at the top of the ID/Relay server dialog, or scan the code with the phone app's scanner.</Muted>
              </Stack>
            </div>
            <div
              aria-label="QR code with these settings"
              role="img"
              style={{ width: 168, height: 168, background: "#fff", borderRadius: 8, padding: 6, flexShrink: 0 }}
              dangerouslySetInnerHTML={{ __html: data.qr }}
            />
          </Row>
        </Card>
      </Section>

      <Section title="Sign-up">
        <Card padding={4}>
          <Switch
            label="Let people create their own RustDesk accounts"
            description="Off: only you create accounts, under Users. On: anyone who can reach this server can register at /api/access/register."
            value={data.registration}
            onChange={(on) => act(() => call("settings.registration", { on }), on ? "Sign-up opened" : "Sign-up closed")}
          />
        </Card>
      </Section>

      <Section title="Recent sessions" actions={<Link to="/admin/audit" search={{ tab: "sessions", page: 1, q: "" }}>All activity</Link>}>
        {data.recentConnections.length === 0 ? (
          <EmptyState isCompact title="No sessions yet" description="Sessions appear once a device with the API server set is connected to." />
        ) : (
          <Table
            density="compact"
            data={data.recentConnections}
            idKey="guid"
            columns={[
              { key: "device", header: "Device", width: proportional(2), renderCell: (c) => <Link to="/admin/devices/$id" params={{ id: c.deviceId }}>{c.deviceName}</Link> },
              { key: "from", header: "From", width: proportional(2), renderCell: (c) => (c.peerId ? `${c.peerName || c.peerId}${c.peerUser ? ` (${c.peerUser})` : ""}` : <Muted>{c.ip || "unknown"}</Muted>) },
              { key: "type", header: "Kind", width: proportional(1), renderCell: (c) => c.type || <Muted>not accepted</Muted> },
              {
                key: "state",
                header: "",
                width: proportional(1),
                renderCell: (c) => (c.blocked ? <Badge variant="error" label="Blocked" /> : c.live ? <Badge variant="success" label="Live" /> : null),
              },
              { key: "at", header: "Started", width: proportional(1), renderCell: (c) => <Ago at={c.startedAt} /> },
            ]}
          />
        )}
      </Section>

      <Section title="Recent events">
        {data.recentEvents.length === 0 ? (
          <EmptyState isCompact title="Nothing logged yet" />
        ) : (
          <Table
            density="compact"
            data={data.recentEvents}
            idKey="seq"
            columns={[
              { key: "category", header: "Kind", width: proportional(1), renderCell: (e) => <Badge variant={e.category === "alarm" ? "error" : "neutral"} label={categoryLabel(e.category)} /> },
              { key: "summary", header: "What happened", width: proportional(4), renderCell: (e) => e.summary },
              { key: "actor", header: "Who", width: proportional(1.5), renderCell: (e) => e.actor || <Muted>—</Muted> },
              { key: "at", header: "When", width: proportional(1), renderCell: (e) => <Ago at={e.at} /> },
            ]}
          />
        )}
      </Section>
    </Page>
  );
}
