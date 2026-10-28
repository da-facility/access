import { useMemo, useState } from "react";
import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { AlertDialog } from "@astryxdesign/core/AlertDialog";
import { Badge } from "@astryxdesign/core/Badge";
import { Banner } from "@astryxdesign/core/Banner";
import { Button } from "@astryxdesign/core/Button";
import { Dialog, DialogHeader } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { MoreMenu } from "@astryxdesign/core/MoreMenu";
import { Selector } from "@astryxdesign/core/Selector";
import { TabList, Tab } from "@astryxdesign/core/TabList";
import { Table, proportional } from "@astryxdesign/core/Table";
import { TextArea } from "@astryxdesign/core/TextArea";
import { TextInput } from "@astryxdesign/core/TextInput";
import { Plus, TriangleAlert } from "lucide-react";
import { describeValue, policyCatalog, policyGroups, policyOption, type PolicyOption } from "../policy-catalog";
import { sourceLabel } from "../lib/labels";
import { call } from "../lib/rpc";
import { DialogActions, DialogBody, Mono, Muted, Online, Page, Row, Section, Stack, useAction } from "../lib/ui";

export const Route = createFileRoute("/admin/policies")({
  validateSearch: (search: Record<string, unknown>) => ({ device: typeof search.device === "string" ? search.device : undefined }),
  loaderDeps: ({ search }) => ({ device: search.device }),
  loader: async ({ deps }) => ({
    ...(await call("policies")),
    inspected: deps.device ? await call("policies.device", { id: deps.device }).catch(() => null) : null,
  }),
  component: Policies,
});

type Data = ReturnType<typeof Route.useLoaderData>;
type Policy = Data["strategies"][number];
const NOT_SET = "__unset__";

function Policies() {
  const data = Route.useLoaderData();
  const { device } = Route.useSearch();
  const navigate = useNavigate({ from: "/admin/policies" });
  const act = useAction();
  const [tab, setTab] = useState(device ? "inspect" : "policies");
  const [editing, setEditing] = useState<Policy | "new" | null>(null);
  const [deleting, setDeleting] = useState<Policy | null>(null);
  const fallback = data.strategies.find((s) => s.isDefault);

  return (
    <Page
      title="Policies"
      description="A policy is a set of RustDesk settings this console pushes to devices, called a “strategy” in RustDesk. Devices pick it up within about 15 seconds of their next check-in, and their user can't change those settings back."
      actions={<Button label="New policy" icon={<Plus size={16} />} onClick={() => setEditing("new")} />}
    >
      <Banner
        status="info"
        title="Which policy a device gets"
        description="Its own override, if set on the device's page. Otherwise its device group's policy. Otherwise the default policy. Otherwise nothing, and the device keeps whatever was set on it locally. Anything a policy leaves unset stays as the device has it."
      />
      <div style={{ marginTop: 18 }}>
        <TabList value={tab} onChange={setTab} hasDivider>
          <Tab value="policies" label="Policies" />
          <Tab value="inspect" label="Inspect a device" />
          <Tab value="catalog" label="Everything a policy can set" />
        </TabList>
      </div>

      {tab === "policies" && (
        <Section title="Policies" description={fallback ? `Devices with nothing else assigned get “${fallback.name}”.` : "No default policy: devices without an assignment get nothing pushed."}>
          {data.strategies.length === 0 ? (
            <EmptyState
              isCompact
              title="No policies yet"
              description="Start by creating one, e.g. “Locked down” with file transfer off and only the permanent password. Then assign it to a device or group, or make it the default."
              actions={<Button label="New policy" onClick={() => setEditing("new")} />}
            />
          ) : (
            <Table
              density="compact"
              data={data.strategies}
              idKey="id"
              columns={[
                {
                  key: "name",
                  header: "Policy",
                  width: proportional(1.6),
                  renderCell: (p) => (
                    <Row gap={6}>
                      <button type="button" onClick={() => setEditing(p)} style={{ all: "unset", cursor: "pointer", fontWeight: 500 }}>
                        {p.name}
                      </button>
                      {p.isDefault && <Badge variant="info" label="Default" />}
                    </Row>
                  ),
                },
                {
                  key: "settings",
                  header: "Sets",
                  width: proportional(3),
                  renderCell: (p) => {
                    const entries = Object.entries(p.options);
                    if (!entries.length) return <Muted>nothing</Muted>;
                    return entries
                      .slice(0, 4)
                      .map(([k, v]) => `${policyOption(k)?.label ?? k}: ${describeValue(policyOption(k), v)}`)
                      .join(" · ") + (entries.length > 4 ? ` · +${entries.length - 4} more` : "");
                  },
                },
                {
                  key: "applies",
                  header: "Assigned to",
                  width: proportional(1.6),
                  renderCell: (p) =>
                    [p.devices ? `${p.devices} device${p.devices === 1 ? "" : "s"}` : "", ...p.groups.map((g) => `group ${g}`)].filter(Boolean).join(", ") || (p.isDefault ? "everything else" : <Muted>nothing</Muted>),
                },
                {
                  key: "menu",
                  header: "",
                  width: { type: "pixel", value: 56 },
                  renderCell: (p) => (
                    <MoreMenu
                      label={`Actions for ${p.name}`}
                      items={[
                        { id: "edit", label: "Edit", onClick: () => setEditing(p) },
                        p.isDefault
                          ? { id: "undefault", label: "Stop using as default", onClick: () => act(() => call("policies.default", { id: null }), "Default cleared") }
                          : { id: "default", label: "Make default", onClick: () => act(() => call("policies.default", { id: p.id }), `${p.name} is now the default`) },
                        { type: "divider" },
                        { id: "delete", label: "Delete", onClick: () => setDeleting(p) },
                      ]}
                    />
                  ),
                },
              ]}
            />
          )}
        </Section>
      )}

      {tab === "inspect" && (
        <Section title="Inspect a device" description="What this console pushes to one device, setting by setting, and where each value comes from.">
          <Stack>
            <Selector
              label="Device"
              hasSearch
              width={420}
              placeholder="Choose a device…"
              options={data.devices.map((d) => ({ value: d.id, label: d.name, description: `${d.id}${d.policyName ? ` · ${d.policyName}` : ""}` }))}
              value={device ?? ""}
              onChange={(id) => navigate({ search: { device: id } })}
            />
            {data.devices.length === 0 && <EmptyState isCompact title="No devices have checked in yet" />}
            {data.inspected && <Inspection inspected={data.inspected} />}
          </Stack>
        </Section>
      )}

      {tab === "catalog" && <Catalog defaults={fallback?.options ?? {}} />}

      {editing && <PolicyDialog policy={editing === "new" ? null : editing} onClose={() => setEditing(null)} />}
      <AlertDialog
        isOpen={!!deleting}
        onOpenChange={(open) => !open && setDeleting(null)}
        title={`Delete ${deleting?.name}?`}
        description="Devices and groups using it fall back to the next policy in line. Settings it pushed are cleared from devices that then get no value for them."
        actionLabel="Delete policy"
        actionVariant="destructive"
        onAction={async () => {
          if (deleting) await act(() => call("policies.delete", { id: deleting.id }), "Policy deleted");
          setDeleting(null);
        }}
      />
    </Page>
  );
}

function Inspection({ inspected }: { inspected: NonNullable<Data["inspected"]> }) {
  const rows = [
    ...policyCatalog.map((o) => ({ key: o.key, option: o as PolicyOption | undefined, value: inspected.options[o.key] as string | undefined })),
    ...Object.keys(inspected.options)
      .filter((k) => !policyOption(k))
      .map((k) => ({ key: k, option: undefined, value: inspected.options[k] })),
  ];
  const pushed = rows.filter((r) => r.value !== undefined);
  return (
    <Stack>
      <Row gap={10}>
        <strong>
          <Link to="/admin/devices/$id" params={{ id: inspected.id }}>
            {inspected.name}
          </Link>
        </strong>
        <Muted>{sourceLabel(inspected.source.kind, inspected.source.groupName)}</Muted>
        {inspected.source.strategy && <Badge variant="info" label={inspected.source.strategy.name} />}
        {inspected.source.kind !== "none" &&
          (inspected.inSync ? <Online online label="Applied" /> : <Badge variant="warning" label="Not applied yet" />)}
      </Row>
      <Muted>
        {pushed.length} of {rows.length} settings are pushed. The rest are whatever the device has locally; RustDesk doesn't report its own settings, so this shows what the console controls.
      </Muted>
      <Table
        density="compact"
        data={rows}
        idKey="key"
        columns={[
          { key: "group", header: "Area", width: proportional(0.9), renderCell: (r) => r.option?.group ?? "Other" },
          {
            key: "label",
            header: "Setting",
            width: proportional(2),
            renderCell: (r) => (
              <span title={r.option?.description}>
                {r.option?.label ?? <Mono>{r.key}</Mono>}
              </span>
            ),
          },
          {
            key: "value",
            header: "Pushed value",
            width: proportional(1.6),
            renderCell: (r) => (r.value === undefined ? <Muted>not pushed</Muted> : <strong>{describeValue(r.option, r.value)}</strong>),
          },
          { key: "default", header: "Client default", width: proportional(1.4), renderCell: (r) => (r.option ? <Muted>{describeValue(r.option, r.option.default)}</Muted> : <Muted>—</Muted>) },
        ]}
      />
    </Stack>
  );
}

function Catalog({ defaults }: { defaults: Record<string, string> }) {
  return (
    <>
      {policyGroups.map((group) => (
        <Section key={group} title={group}>
          <Table
            density="compact"
            data={policyCatalog.filter((o) => o.group === group)}
            idKey="key"
            columns={[
              {
                key: "label",
                header: "Setting",
                width: proportional(1.6),
                renderCell: (o) => (
                  <Row gap={6}>
                    {o.label}
                    {o.dangerous && <TriangleAlert size={14} aria-label="Can cut the device off" color="var(--color-text-warning, #b45309)" />}
                  </Row>
                ),
              },
              { key: "description", header: "What it does", width: proportional(4), renderCell: (o) => <Muted>{o.description}</Muted> },
              { key: "default", header: "Client default", width: proportional(1.2), renderCell: (o) => describeValue(o, o.default) },
              { key: "policy", header: "Default policy", width: proportional(1.2), renderCell: (o) => (o.key in defaults ? <strong>{describeValue(o, defaults[o.key])}</strong> : <Muted>not set</Muted>) },
              { key: "key", header: "Key", width: proportional(1.8), renderCell: (o) => <Mono>{o.key}</Mono> },
            ]}
          />
        </Section>
      ))}
    </>
  );
}

function PolicyDialog({ policy, onClose }: { policy: Policy | null; onClose: () => void }) {
  const act = useAction();
  const [name, setName] = useState(policy?.name ?? "");
  const [note, setNote] = useState(policy?.note ?? "");
  const [options, setOptions] = useState<Record<string, string>>(() => Object.fromEntries(Object.entries(policy?.options ?? {}).filter(([k]) => policyOption(k))) as Record<string, string>);
  const [extra, setExtra] = useState(() =>
    Object.entries(policy?.options ?? {})
      .filter(([k]) => !policyOption(k))
      .map(([k, v]) => `${k}=${v}`)
      .join("\n"),
  );
  const [group, setGroup] = useState<string>(policyGroups[0]);
  const set = (key: string, value: string | undefined) =>
    setOptions((current) => {
      const next = { ...current };
      if (value === undefined) delete next[key];
      else next[key] = value;
      return next;
    });
  const counts = useMemo(() => Object.fromEntries(policyGroups.map((g) => [g, policyCatalog.filter((o) => o.group === g && o.key in options).length])), [options]);
  const save = async () => {
    const custom: Record<string, string> = {};
    for (const line of extra.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed) continue;
      const at = trimmed.indexOf("=");
      if (at < 1) return void (await act(async () => Promise.reject(new Error(`“${trimmed}” needs to look like key=value.`))));
      custom[trimmed.slice(0, at).trim()] = trimmed.slice(at + 1).trim();
    }
    if (await act(() => call("policies.save", { id: policy?.id, name, note, options: { ...custom, ...options } }), "Policy saved")) onClose();
  };
  return (
    <Dialog isOpen onOpenChange={(open) => !open && onClose()} width={760} maxHeight="90vh" purpose="form">
      <DialogHeader title={policy ? `Edit ${policy.name}` : "New policy"} subtitle="Only the settings you set are pushed; the rest stay as each device has them." onOpenChange={(open) => !open && onClose()} />
      <DialogBody>
        <Row wrap={false}>
          <div style={{ flex: 1 }}>
            <TextInput label="Name" value={name} onChange={setName} isRequired hasAutoFocus />
          </div>
          <div style={{ flex: 2 }}>
            <TextInput label="Note" value={note} onChange={setNote} isOptional />
          </div>
        </Row>
        <TabList value={group} onChange={setGroup} hasDivider>
          {policyGroups.map((g) => (
            <Tab key={g} value={g} label={counts[g] ? `${g} (${counts[g]})` : g} />
          ))}
          <Tab value="Other" label="Other keys" />
        </TabList>
        {group === "Other" ? (
          <TextArea
            label="Other option keys"
            description="One key=value per line, for RustDesk options not listed in the other tabs. Values are sent as-is."
            value={extra}
            onChange={setExtra}
            rows={6}
          />
        ) : (
          <Stack gap={10}>
            {policyCatalog
              .filter((o) => o.group === group)
              .map((o) => (
                <OptionField key={o.key} option={o} value={options[o.key]} onChange={(v) => set(o.key, v)} />
              ))}
          </Stack>
        )}
      </DialogBody>
      <DialogActions>
        <Button label="Cancel" variant="ghost" onClick={onClose} />
        <Button label="Save policy" clickAction={save} />
      </DialogActions>
    </Dialog>
  );
}

function OptionField({ option, value, onChange }: { option: PolicyOption; value: string | undefined; onChange: (value: string | undefined) => void }) {
  const description = `${option.description} Client default: ${describeValue(option, option.default)}.`;
  const label = option.dangerous ? `${option.label} ⚠` : option.label;
  if (option.kind === "toggle" || option.choices) {
    const choices = option.kind === "toggle" ? [{ value: "Y", label: "On" }, { value: "N", label: "Off" }] : option.choices!;
    return (
      <Selector
        label={label}
        description={description}
        options={[{ value: NOT_SET, label: "Not set — leave as the device has it" }, ...choices.map((c) => ({ value: c.value === "" ? "__empty__" : c.value, label: c.label }))]}
        value={value === undefined ? NOT_SET : value === "" ? "__empty__" : value}
        onChange={(v) => onChange(v === NOT_SET ? undefined : v === "__empty__" ? "" : v)}
      />
    );
  }
  return (
    <TextInput
      label={label}
      description={`${description} Leave empty to not set it.`}
      type="text"
      value={value ?? ""}
      onChange={(v) => onChange(v === "" ? undefined : v)}
    />
  );
}
