import { useEffect, useState } from "react";
import { startMirror, useMirror } from "./state/app";
import { useUI } from "./state/ui";
import { BorderedButton } from "./components/controls";
import { Workspace } from "./components/workspace/Workspace";
import styles from "./app.module.css";

/** Mirrors main's state, then shows the workspace. A failed first snapshot can be retried. */
export function App() {
  const ready = useMirror((s) => s.ready);
  const error = useUI((s) => s.error);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => startMirror(), [attempt]);
  if (ready) return <Workspace />;
  return (
    <div className={styles.loading} role="status">
      <span>{error ?? "Opening workspace…"}</span>
      {error && <BorderedButton onClick={() => { useUI.setState({ error: null }); setAttempt((a) => a + 1); }}>Try again</BorderedButton>}
    </div>
  );
}
