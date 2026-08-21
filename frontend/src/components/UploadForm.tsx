import { useCallback, useState } from "react";
import { useDropzone } from "react-dropzone";
import { getUploadStatus, startUpload, uploadFileToS3 } from "../api";

const TERMINAL_STATUSES = new Set(["succeeded", "partially_succeeded", "failed"]);
const POLL_INTERVAL_MS = 3000;

async function pollUntilTerminal(uploadId: string): Promise<void> {
  const result = await getUploadStatus(uploadId);
  if (TERMINAL_STATUSES.has(result.status)) return;
  await new Promise((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  return pollUntilTerminal(uploadId);
}

export function UploadForm({ onUploadComplete }: { onUploadComplete: () => void }) {
  const [status, setStatus] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const onDrop = useCallback(
    async ([file]: File[]) => {
      if (!file) return;
      setError(null);
      setStatus("Starting upload…");
      try {
        const presigned = await startUpload(file.name);
        setStatus("Uploading to S3…");
        await uploadFileToS3(presigned, file);
        setStatus("Processing…");
        await pollUntilTerminal(presigned.upload_id);
        setStatus(null);
        onUploadComplete();
      } catch {
        setError("Upload failed. Please try again.");
        setStatus(null);
      }
    },
    [onUploadComplete],
  );

  const { getRootProps, getInputProps, isDragActive } = useDropzone({
    onDrop,
    accept: { "text/csv": [".csv"] },
    maxFiles: 1,
    disabled: status !== null,
  });

  return (
    <div>
      <div
        {...getRootProps()}
        className={`flex cursor-pointer flex-col items-center justify-center rounded-xl border-2 border-dashed px-6 py-10 text-center transition ${
          isDragActive
            ? "border-indigo-400 bg-indigo-50"
            : "border-slate-300 bg-white hover:border-indigo-300 hover:bg-slate-50"
        } ${status !== null ? "cursor-not-allowed opacity-60" : ""}`}
      >
        <input {...getInputProps()} />
        <svg
          className="mb-3 h-10 w-10 text-slate-400"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
        >
          <path
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeWidth={1.5}
            d="M3 16.5v2.25A2.25 2.25 0 0 0 5.25 21h13.5A2.25 2.25 0 0 0 21 18.75V16.5M16.5 12 12 16.5m0 0L7.5 12m4.5 4.5V3"
          />
        </svg>
        {status ? (
          <p className="text-sm font-medium text-slate-600">{status}</p>
        ) : isDragActive ? (
          <p className="text-sm font-medium text-indigo-600">Drop the CSV here</p>
        ) : (
          <>
            <p className="text-sm font-medium text-slate-700">
              Drag and drop a CSV file, or click to browse
            </p>
            <p className="mt-1 text-xs text-slate-400">Up to 10MB, .csv only</p>
          </>
        )}
      </div>
      {error && <p className="mt-2 text-sm text-red-600">{error}</p>}
    </div>
  );
}
