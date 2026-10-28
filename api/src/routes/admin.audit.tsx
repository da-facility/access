import { useState } from "react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { Badge } from "@astryxdesign/core/Badge";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Pagination } from "@astryxdesign/core/Pagination";
import { TabList, Tab } from "@astryxdesign/core/TabList";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Search } from "lucide-react";
import { call } from "../lib/rpc";
import { Ago, Mono, Muted, Page, Stack } from "../lib/ui";

const PAGE = 50;
const tabs = [
  { value: "sessions", label: "Sessions" },
  { value: "file", label: "File transfers" },
  { value: "alarm", label: "Alarms" },
  { value: "login", label: "Sign-ins" },
  { value: "device", label: "Devices" },
  { value: "console", label: "Console changes" },
] as const;
type TabValue = (typeof tabs)[number]["value"];

export const Route = createFileRoute("/admin/audit")({
  validateSearch: (search: Record<string, unknown>) => ({
    tab: (tabs.some((t) => t.value === search.tab) ? search.tab : "sessions") as TabValue,
    page: Math.max(1, Number(search.page) || 1),
    q: typeof search.q === "string" ? search.q : "",
  }),
  loaderDeps: ({ search }) => search,
  loader: async ({ deps }) => {
    const paging = { limit: PAGE, offset: (deps.page - 1) * PAGE, search: deps.q || undefined };
    return deps.tab === "sessions"
      ? { kind: "sessions" as const, ...(await call("audit.connections", paging)) }
      : { kind: "events" as const, ...(await call("audit.events", { ...paging, category: deps.tab })) };
  },
  component: Audit,
});

function Audit() {
  const data = Route.useLoaderData();
  const search = Route.useSearch();
  const navigate = useNavigate({ from: "/admin/audit" });
  const [query, setQuery] = useState(search.q);
  return (
    <Page
      title="Audit log"
      description="Devices report sessions, file transfers and security alarms here as they happen; sign-ins and console changes are logged by this server. Entries are kept for a year."
    >
      <Stack>
        <TabList value={search.tab} onChange={(tab) => navigate({ search: { tab: tab as TabValue, page: 1, q: search.q } })} hasDivider>
          {tabs.map((t) => (
            <Tab key={t.value} value={t.value} label={t.label} />
          ))}
        </TabList>
        <TextInput
          label="Search"
          isLabelHidden
          placeholder="Search by device, ID, user, IP or text… then press Enter"
          value={query}
          onChange={setQuery}
          onEnter={() => navigate({ search: { ...search, page: 1, q: query } })}
          hasClear
          startIcon={<Search size={16} />}
          width={420}
        />
        {data.items.length === 0 ? (
          <EmptyState isCompact title="Nothing here" description={search.q ? "No entries match the search." : "Entries appear as soon as something happens."} />
        ) : data.kind === "sessions" ? (
          <Table
            density="compact"
            data={data.items}
            idKey="guid"
            columns={[
              {
                key: "device",
                header: "Device",
                width: proportional(1.6),
                renderCell: (c) => (
                  <Link to="/admin/devices/$id" params={{ id: c.deviceId }}>
                    {c.deviceName}
                  </Link>
                ),
              },
              {
                key: "from",
                header: "Connected from",
                width: proportional(2.2),
                renderCell: (c) => (
                  <div style={{ display: "flex", flexDirection: "column" }}>
                    <span>{c.peerId ? `${c.peerName || c.peerId}${c.peerUser ? ` (${c.peerUser})` : ""}` : "—"}</span>
                    <Muted>
                      {c.peerId && <Mono>{c.peerId}</Mono>} {c.ip}
                    </Muted>
                  </div>
                ),
              },
              { key: "type", header: "Kind", width: proportional(1.2), renderCell: (c) => c.type || <Muted>not accepted</Muted> },
              { key: "auth", header: "Accepted by", width: proportional(1.4), renderCell: (c) => (c.auth ? `${c.auth}${c.twoFactor ? " + 2FA" : ""}` : <Muted>—</Muted>) },
              { key: "start", header: "Started", width: proportional(1), renderCell: (c) => <Ago at={c.startedAt} /> },
              {
                key: "duration",
                header: "Length",
                width: proportional(1),
                renderCell: (c) =>
                  c.blocked ? (
                    <Badge variant="error" label="Blocked" />
                  ) : c.live ? (
                    <Badge variant="success" label="Live" />
                  ) : c.endedAt ? (
                    `${Math.max(1, Math.round((c.endedAt - c.startedAt) / 60))} min`
                  ) : (
                    <Muted>—</Muted>
                  ),
              },
              { key: "note", header: "Note", width: proportional(1.5), renderCell: (c) => c.note || <Muted>—</Muted> },
            ]}
          />
        ) : (
          <Table
            density="compact"
            data={data.items}
            idKey="seq"
            columns={[
              { key: "at", header: "When", width: proportional(1), renderCell: (e) => <Ago at={e.at} /> },
              { key: "summary", header: "What happened", width: proportional(4), renderCell: (e) => e.summary },
              {
                key: "device",
                header: "Device",
                width: proportional(1.4),
                renderCell: (e) =>
                  e.deviceId ? (
                    <Link to="/admin/devices/$id" params={{ id: e.deviceId }}>
                      {e.deviceName}
                    </Link>
                  ) : (
                    <Muted>—</Muted>
                  ),
              },
              { key: "actor", header: "Who", width: proportional(1.4), renderCell: (e) => e.actor || (e.peerId ? <Mono>{e.peerId}</Mono> : <Muted>—</Muted>) },
              { key: "ip", header: "IP", width: proportional(1.1), renderCell: (e) => e.ip || <Muted>—</Muted> },
            ]}
          />
        )}
        {data.total > PAGE && <Pagination page={search.page} totalItems={data.total} pageSize={PAGE} onChange={(page) => navigate({ search: { ...search, page } })} />}
      </Stack>
    </Page>
  );
}
