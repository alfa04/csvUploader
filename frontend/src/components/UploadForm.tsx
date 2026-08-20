import { useState } from "react";
import { getUploadStatus, startUpload, uploadFileToS3 } from "../api";

const TERMINAL_STATUSES = new Set(["succeeded", "partially_succeeded", "failed"]);
const POLL_INTERVAL_MS = 3000;

export function UploadForm({ onUploadComplete }: { onUploadComplete: () => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!file) return;

    setError(null);
    setStatus("starting upload...");
    try {
      const presigned = await startUpload(file.name);
      setStatus("uploading to S3...");
      await uploadFileToS3(presigned, file);
      setStatus("processing...");
      await pollUntilTerminal(presigned.upload_id);
      setStatus(null);
      setFile(null);
      onUploadComplete();
    } catch {
      setError("Upload failed. Please try again.");
      setStatus(null);
    }
  }

  async function pollUntilTerminal(uploadId: string): Promise<void> {
    const result = await getUploadStatus(uploadId);
    if (TERMINAL_STATUSES.has(result.status)) {
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
    return pollUntilTerminal(uploadId);
  }

  return (
    <form onSubmit={handleSubmit}>
      <input
        type="file"
        accept=".csv,text/csv"
        onChange={(e) => setFile(e.target.files?.[0] ?? null)}
      />
      <button type="submit" disabled={!file || status !== null}>
        Upload
      </button>
      {status && <p>{status}</p>}
      {error && <p>{error}</p>}
    </form>
  );
}
