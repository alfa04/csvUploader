import { useCallback, useEffect, useState } from "react";
import { listUploads, type UploadSummary } from "../api";
import { SummaryStats } from "../components/SummaryStats";
import { UploadForm } from "../components/UploadForm";
import { UploadList } from "../components/UploadList";

export function Dashboard({ signOut }: { signOut?: () => void }) {
  const [uploads, setUploads] = useState<UploadSummary[]>([]);
  const [error, setError] = useState<string | null>(null);

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
    <main>
      <button onClick={signOut}>Sign out</button>
      <h1>Your uploads</h1>
      {error && (
        <p>
          {error} <button onClick={refresh}>Retry</button>
        </p>
      )}
      <UploadForm onUploadComplete={refresh} />
      <SummaryStats uploads={uploads} />
      <UploadList uploads={uploads} />
    </main>
  );
}
