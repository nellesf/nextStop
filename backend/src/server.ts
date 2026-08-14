import { createApp } from "./api/app.js";

function parsePort(value: string | undefined): number {
  if (value === undefined) {
    return 3_000;
  }

  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > 65_535) {
    throw new Error("PORT must be an integer from 1 through 65535.");
  }
  return parsed;
}

const app = createApp();

await app.listen({
  host: process.env.HOST ?? "127.0.0.1",
  port: parsePort(process.env.PORT),
});
