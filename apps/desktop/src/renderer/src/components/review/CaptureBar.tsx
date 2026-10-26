import { attachmentLabel, type CodeAttachment } from "@octo/core";
import { attachToDraft } from "../../lib/workspace";
import { PrimaryButton } from "../controls";
import styles from "./review.module.css";

/** The selected code and Ask Agent, which attaches it to the draft without sending. */
export function CaptureBar({ selection }: { selection?: CodeAttachment }) {
  return (
    <div className={styles.captureBar}>
      <span>{selection ? attachmentLabel(selection) : "Hover a line and click + to attach code"}</span>
      <PrimaryButton pill small disabled={!selection} help="Attach the selected code to the draft (⇧⌘A)" onClick={() => { if (selection) attachToDraft(selection); }}>Ask Agent</PrimaryButton>
    </div>
  );
}
