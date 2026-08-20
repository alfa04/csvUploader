import { Authenticator } from "@aws-amplify/ui-react";
import "@aws-amplify/ui-react/styles.css";

export default function App() {
  return (
    <Authenticator>
      {({ signOut, user }) => (
        <main>
          <p>Signed in as {user?.signInDetails?.loginId}</p>
          <button onClick={signOut}>Sign out</button>
        </main>
      )}
    </Authenticator>
  );
}
