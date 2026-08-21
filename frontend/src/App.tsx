import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";
import { Dashboard } from "./pages/Dashboard";

export default function App() {
  return (
    <div className="min-h-screen bg-slate-50">
      <Authenticator>
        {({ signOut }) => <Dashboard signOut={signOut} />}
      </Authenticator>
    </div>
  );
}
