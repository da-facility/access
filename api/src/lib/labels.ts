export const categoryLabel = (category: string) =>
  ({ file: "File transfer", alarm: "Alarm", login: "Sign-in", console: "Console", device: "Device" })[category] ?? category;

export const sourceLabel = (kind: string, groupName?: string) =>
  kind === "device" ? "Set on this device" : kind === "group" ? `From group ${groupName ?? ""}`.trim() : kind === "default" ? "Default policy" : "No policy";
