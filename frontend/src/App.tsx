import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";
import { Dashboard } from "./pages/Dashboard";

export default function App() {
  return (
    <Authenticator>
      {({ signOut }) => <Dashboard signOut={signOut} />}
    </Authenticator>
  );
}
