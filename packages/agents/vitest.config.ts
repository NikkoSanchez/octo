import { defineProject } from "vitest/config";

export default defineProject({
  test: {
    name: "agents",
    include: ["test/**/*.test.ts"],
    environment: "node",
  },
});
