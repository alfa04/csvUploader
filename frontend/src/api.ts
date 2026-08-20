import { fetchAuthSession } from "aws-amplify/auth";

const API_URL = import.meta.env.VITE_API_URL;

export interface UploadSummary {
  upload_id: string;
  status: "pending" | "processing" | "succeeded" | "partially_succeeded" | "failed";
  original_filename: string;
  created_at: string;
  updated_at: string;
  row_count: number;
  valid_row_count: number;
  invalid_row_count: number;
}

export interface PresignedUpload {
  upload_id: string;
  upload_url: string;
  upload_fields: Record<string, string>;
  expires_in: number;
}

async function authHeaders(): Promise<Record<string, string>> {
  const session = await fetchAuthSession();
  const idToken = session.tokens?.idToken?.toString();
  return { Authorization: `Bearer ${idToken}` };
}

async function apiFetch<T>(path: string, init?: RequestInit): Promise<T> {
  const headers = { ...(await authHeaders()), ...init?.headers };
  const response = await fetch(`${API_URL}${path}`, { ...init, headers });
  if (!response.ok) {
    throw new Error(`Request to ${path} failed with status ${response.status}`);
  }
  return response.json() as Promise<T>;
}

export async function listUploads(): Promise<{ uploads: UploadSummary[] }> {
  return apiFetch<{ uploads: UploadSummary[] }>("/uploads?limit=100");
}

export async function startUpload(filename: string): Promise<PresignedUpload> {
  return apiFetch<PresignedUpload>("/uploads", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ filename }),
  });
}

export async function getUploadStatus(uploadId: string): Promise<UploadSummary> {
  return apiFetch<UploadSummary>(`/uploads/${uploadId}`);
}

export async function uploadFileToS3(presigned: PresignedUpload, file: File): Promise<void> {
  const formData = new FormData();
  for (const [key, value] of Object.entries(presigned.upload_fields)) {
    formData.append(key, value);
  }
  formData.append("file", file);

  const response = await fetch(presigned.upload_url, { method: "POST", body: formData });
  if (!response.ok) {
    throw new Error(`S3 upload failed with status ${response.status}`);
  }
}
