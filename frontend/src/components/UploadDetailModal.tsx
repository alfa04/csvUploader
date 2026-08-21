import { useEffect, useState } from "react";
import { getUploadRecords, type DataRecord, type UploadSummary } from "../api";
import { StatusBadge } from "./StatusBadge";
import { JsonView, defaultStyles } from "react-json-view-lite";
import "react-json-view-lite/dist/index.css";

export function UploadDetailModal({
  uploadId,
  uploads,
  onClose,
}: {
  uploadId: string;
  uploads: UploadSummary[];
  onClose: () => void;
}) {
  const upload = uploads.find((u) => u.upload_id === uploadId);
  const [records, setRecords] = useState<DataRecord[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setRecords(null);
    setLoadError(null);
    getUploadRecords(uploadId)
      .then((page) => {
        if (!cancelled) setRecords(page.records);
      })
      .catch(() => {
        if (!cancelled) setLoadError("Failed to load records.");
      });
    return () => {
      cancelled = true;
    };
  }, [uploadId]);

  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") onClose();
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [onClose]);

  if (!upload) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4"
      onClick={onClose}
    >
      <div
        className="flex max-h-[85vh] w-full max-w-2xl flex-col rounded-xl bg-white shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-start justify-between border-b border-slate-200 px-6 py-4">
          <div>
            <h3 className="text-base font-semibold text-slate-900">{upload.original_filename}</h3>
            <div className="mt-1 flex items-center gap-2">
              <StatusBadge status={upload.status} />
              <span className="text-sm text-slate-500">
                {upload.valid_row_count}/{upload.row_count} rows valid
              </span>
            </div>
          </div>
          <button
            onClick={onClose}
            className="rounded-md p-1 text-slate-400 transition hover:bg-slate-100 hover:text-slate-600"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        <div className="flex-1 overflow-y-auto px-6 py-4">
          {upload.errors.length > 0 && (
            <div className="mb-4">
              <h4 className="mb-2 text-sm font-semibold text-slate-700">
                Row errors ({upload.errors.length})
              </h4>
              <div className="max-h-40 overflow-y-auto rounded-lg border border-red-100 bg-red-50">
                <table className="w-full text-xs">
                  <tbody className="divide-y divide-red-100">
                    {upload.errors.map((e, i) => (
                      <tr key={i}>
                        <td className="whitespace-nowrap px-3 py-1.5 font-mono text-red-700">
                          row {e.row}
                        </td>
                        <td className="whitespace-nowrap px-3 py-1.5 font-medium text-red-700">
                          {e.field}
                        </td>
                        <td className="px-3 py-1.5 text-red-600">{e.message}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          <h4 className="mb-2 text-sm font-semibold text-slate-700">Parsed data</h4>
          {loadError && <p className="text-sm text-red-600">{loadError}</p>}
          {!loadError && records === null && <p className="text-sm text-slate-500">Loading…</p>}
          {records !== null && records.length === 0 && (
            <p className="text-sm text-slate-500">No parsed records for this upload.</p>
          )}
          {records !== null && records.length > 0 && (
            <div className="rounded-lg border border-slate-200 bg-slate-50 p-3">
              <JsonView data={{ records }} style={defaultStyles} />
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
