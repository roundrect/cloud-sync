// A namespace is one app's slice of an account: its own document, history and sockets, and its own devices.
// The slug can't contain ':', which separates it from the account in a document's name.

const SLUG_RE = /^[a-z][a-z0-9-]{0,31}$/;

export const isSlug = (value: unknown): value is string => typeof value === "string" && SLUG_RE.test(value);

/** The Durable Object name of a namespace's document: `<account>:<namespace>`. */
export const docName = (accountId: string, namespace: string): string => `${accountId}:${namespace}`;
