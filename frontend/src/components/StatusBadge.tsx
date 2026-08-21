const STYLES: Record<string, string> = {
  succeeded: "bg-emerald-50 text-emerald-700 ring-emerald-600/20",
  partially_succeeded: "bg-amber-50 text-amber-700 ring-amber-600/20",
  failed: "bg-red-50 text-red-700 ring-red-600/20",
  pending: "bg-slate-100 text-slate-600 ring-slate-500/20",
  processing: "bg-blue-50 text-blue-700 ring-blue-600/20",
};

const LABELS: Record<string, string> = {
  succeeded: "Succeeded",
  partially_succeeded: "Partial",
  failed: "Failed",
  pending: "Pending",
  processing: "Processing",
};

export function StatusBadge({ status }: { status: string }) {
  return (
    <span
      className={`inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium ring-1 ring-inset ${
        STYLES[status] ?? STYLES.pending
      }`}
    >
      {LABELS[status] ?? status}
    </span>
  );
}
