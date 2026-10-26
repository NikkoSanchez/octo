/// <reference types="vite/client" />
import type { OctoBridge } from "../../shared/ipc";

declare global {
  interface Window {
    octo: OctoBridge;
  }
}
