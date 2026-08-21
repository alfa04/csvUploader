import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";
import { Dashboard } from "./pages/Dashboard";

// Renders inside Amplify's own centered [data-amplify-container], directly above the sign-in/
// sign-up card - shown on every auth screen (sign in, sign up, confirm code, etc.).
const authComponents = {
  Header() {
    return (
      <div className="mb-6 text-center">
        <h1 className="text-2xl font-bold tracking-tight text-slate-900">csvUploader</h1>
        <p className="mt-1 text-sm text-slate-500">Upload, validate, and explore your data</p>
      </div>
    );
  },
};

export default function App() {
  return (
    <div className="min-h-screen bg-slate-50">
      <Authenticator components={authComponents}>
        {({ signOut }) => <Dashboard signOut={signOut} />}
      </Authenticator>
    </div>
  );
}
