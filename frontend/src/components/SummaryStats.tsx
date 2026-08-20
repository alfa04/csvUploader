import type { UploadSummary } from "../api";

const TERMINAL_SUCCESS = new Set(["succeeded", "partially_succeeded"]);

export function SummaryStats({ uploads }: { uploads: UploadSummary[] }) {
  const total = uploads.length;
  const terminal = uploads.filter(
    (u) => u.status !== "pending" && u.status !== "processing",
  );
  const successRate =
    terminal.length === 0
      ? null
      : Math.round(
          (terminal.filter((u) => TERMINAL_SUCCESS.has(u.status)).length / terminal.length) * 100,
        );
  const totalRows = uploads.reduce((sum, u) => sum + u.valid_row_count, 0);

  return (
    <div>
      <span>Total uploads: {total}</span>
      {" · "}
      <span>Success rate: {successRate === null ? "n/a" : `${successRate}%`}</span>
      {" · "}
      <span>Rows processed: {totalRows}</span>
    </div>
  );
}
