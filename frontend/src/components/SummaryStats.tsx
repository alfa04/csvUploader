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

  const stats = [
    { label: "Total uploads", value: String(total) },
    { label: "Success rate", value: successRate === null ? "—" : `${successRate}%` },
    { label: "Rows processed", value: totalRows.toLocaleString() },
  ];

  return (
    <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
      {stats.map((stat) => (
        <div
          key={stat.label}
          className="rounded-xl border border-slate-200 bg-white p-5 shadow-sm"
        >
          <p className="text-sm font-medium text-slate-500">{stat.label}</p>
          <p className="mt-1 text-2xl font-semibold tracking-tight text-slate-900">
            {stat.value}
          </p>
        </div>
      ))}
    </div>
  );
}
