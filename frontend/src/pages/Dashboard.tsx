import { useCallback, useEffect, useState } from "react";
import { listUploads, type UploadSummary } from "../api";
import { SummaryStats } from "../components/SummaryStats";
import { UploadDetailModal } from "../components/UploadDetailModal";
import { UploadForm } from "../components/UploadForm";
import { UploadList } from "../components/UploadList";

export function Dashboard({ signOut }: { signOut?: () => void }) {
  const [uploads, setUploads] = useState<UploadSummary[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [selectedUploadId, setSelectedUploadId] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const { uploads: fetched } = await listUploads();
      setUploads(fetched);
      setError(null);
    } catch {
      setError("Failed to load uploads.");
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return (
    <div className="min-h-screen bg-slate-50">
      <header className="border-b border-slate-200 bg-white">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <h1 className="text-lg font-semibold tracking-tight text-slate-900">csvUploader</h1>
          <button
            onClick={signOut}
            className="rounded-md border border-slate-300 px-3 py-1.5 text-sm font-medium text-slate-700 transition hover:bg-slate-100"
          >
            Sign out
          </button>
        </div>
      </header>

      <main className="mx-auto max-w-6xl px-6 py-8">
        {error && (
          <div className="mb-6 flex items-center justify-between rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800">
            <span>{error}</span>
            <button onClick={refresh} className="font-medium underline hover:no-underline">
              Retry
            </button>
          </div>
        )}

        <UploadForm onUploadComplete={refresh} />

        <div className="mt-8">
          <SummaryStats uploads={uploads} />
        </div>

        <div className="mt-8">
          <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-slate-500">
            Upload history
          </h2>
          <UploadList uploads={uploads} onSelect={setSelectedUploadId} />
        </div>
      </main>

      {selectedUploadId && (
        <UploadDetailModal
          uploadId={selectedUploadId}
          uploads={uploads}
          onClose={() => setSelectedUploadId(null)}
        />
      )}
    </div>
  );
}
