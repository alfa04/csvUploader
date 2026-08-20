import type { UploadSummary } from "../api";

export function UploadList({ uploads }: { uploads: UploadSummary[] }) {
  if (uploads.length === 0) {
    return <p>No uploads yet.</p>;
  }

  return (
    <table>
      <thead>
        <tr>
          <th>File</th>
          <th>Status</th>
          <th>Rows</th>
          <th>Uploaded</th>
        </tr>
      </thead>
      <tbody>
        {uploads.map((u) => (
          <tr key={u.upload_id}>
            <td>{u.original_filename}</td>
            <td>{u.status}</td>
            <td>{u.valid_row_count}</td>
            <td>{new Date(u.created_at).toLocaleString()}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
