import type { UploadSummary } from "../api";
import { StatusBadge } from "./StatusBadge";

export function UploadList({
  uploads,
  onSelect,
}: {
  uploads: UploadSummary[];
  onSelect: (uploadId: string) => void;
}) {
  if (uploads.length === 0) {
    return (
      <div className="rounded-xl border border-dashed border-slate-300 bg-white p-10 text-center text-sm text-slate-500">
        No uploads yet. Drop a CSV above to get started.
      </div>
    );
  }

  return (
    <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-sm">
      <table className="min-w-full divide-y divide-slate-200 text-sm">
        <thead className="bg-slate-50">
          <tr>
            <th className="px-4 py-3 text-left font-medium text-slate-500">File</th>
            <th className="px-4 py-3 text-left font-medium text-slate-500">Status</th>
            <th className="px-4 py-3 text-left font-medium text-slate-500">Rows</th>
            <th className="px-4 py-3 text-left font-medium text-slate-500">Uploaded</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {uploads.map((u) => (
            <tr
              key={u.upload_id}
              onClick={() => onSelect(u.upload_id)}
              className="cursor-pointer transition hover:bg-slate-50"
            >
              <td className="px-4 py-3 font-medium text-slate-900">{u.original_filename}</td>
              <td className="px-4 py-3">
                <div className="flex items-center gap-2">
                  <StatusBadge status={u.status} />
                  {u.invalid_row_count > 0 && (
                    <span className="text-xs font-medium text-red-600">
                      {u.invalid_row_count} error{u.invalid_row_count === 1 ? "" : "s"}
                    </span>
                  )}
                </div>
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-slate-600">
                {u.valid_row_count}/{u.row_count}
              </td>
              <td className="whitespace-nowrap px-4 py-3 text-slate-600">
                {new Date(u.created_at).toLocaleString()}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
