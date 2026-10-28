import { useMemo, useState } from "react";
import { createFileRoute, Link } from "@tanstack/react-router";
import { Badge } from "@astryxdesign/core/Badge";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Monitor, Search } from "lucide-react";
import { call } from "../lib/rpc";
import { Ago, Muted, Online, Page, Stack } from "../lib/ui";

export const Route = createFileRoute("/admin/devices/")({
  loader: () => call("devices.list"),
  component: Devices,
});

function Devices() {
  const { devices } = Route.useLoaderData();
  const [query, setQuery] = useState("");
  const shown = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return devices;
    return devices.filter((d) =>
      [d.id, d.hostname, d.alias, d.username, d.os, d.ip, d.ownerName ?? "", d.groupName ?? ""].some((v) => v.toLowerCase().includes(q)),
    );
  }, [devices, query]);
  return (
    <Page
      title="Devices"
      description="Every RustDesk client whose API server is this console. They check in every few seconds while running; new ones appear here on their own."
    >
      <Stack>
        <TextInput label="Search devices" isLabelHidden placeholder="Search by ID, name, user, group, IP…" value={query} onChange={setQuery} startIcon={<Search size={16} />} hasClear width={360} />
        {devices.length === 0 ? (
          <EmptyState
            icon={<Monitor size={28} />}
            title="No devices have checked in"
            description="In a RustDesk client, set the API server to this console's address (see Overview). The device shows up within a few seconds."
          />
        ) : (
          <Table
            density="compact"
            hasHover
            data={shown}
            idKey="id"
            columns={[
              { key: "online", header: "", width: { type: "pixel", value: 36 }, renderCell: (d) => <Online online={d.online} label={d.online ? "Online" : "Offline"} /> },
              {
                key: "name",
                header: "Device",
                width: proportional(2.2),
                renderCell: (d) => (
                  <div style={{ display: "flex", flexDirection: "column" }}>
                    <Link to="/admin/devices/$id" params={{ id: d.id }}>
                      {d.alias || d.hostname || d.id}
                    </Link>
                    <Muted>
                      {d.id}
                      {d.username ? ` · ${d.username}` : ""}
                    </Muted>
                  </div>
                ),
              },
              { key: "os", header: "System", width: proportional(2), renderCell: (d) => <span title={d.os}>{d.os.split(" / ")[0] || "—"}{d.version ? <Muted> · {d.version}</Muted> : null}</span> },
              { key: "owner", header: "Owner", width: proportional(1.2), renderCell: (d) => d.ownerName ?? <Muted>—</Muted> },
              { key: "group", header: "Group", width: proportional(1.2), renderCell: (d) => d.groupName ?? <Muted>—</Muted> },
              {
                key: "policy",
                header: "Policy",
                width: proportional(1.6),
                renderCell: (d) =>
                  d.policyName ? (
                    <span style={{ display: "inline-flex", gap: 6, alignItems: "center" }}>
                      {d.policyName}
                      {!d.policyInSync && <Badge variant="warning" label="Pending" />}
                    </span>
                  ) : (
                    <Muted>None</Muted>
                  ),
              },
              {
                key: "state",
                header: "",
                width: proportional(1),
                renderCell: (d) =>
                  d.disabled ? <Badge variant="error" label="Blocked" /> : d.activeConns > 0 ? <Badge variant="success" label={`${d.activeConns} in session`} /> : null,
              },
              { key: "seen", header: "Last seen", width: proportional(1), renderCell: (d) => (d.online ? <Muted>now</Muted> : <Ago at={d.lastSeen} />) },
            ]}
          />
        )}
      </Stack>
    </Page>
  );
}
