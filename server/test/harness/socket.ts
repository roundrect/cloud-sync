import type { RawSocket } from "./types";

/** Wraps an event-style socket so messages that arrive before a listener is attached are not lost. */
export function bufferedSocket(
  send: (text: string) => void,
  close: (code?: number) => void,
): { socket: RawSocket; deliver(text: string): void; closed(code: number, reason: string): void } {
  const messages: string[] = [];
  let onMessage: ((text: string) => void) | undefined;
  let onClose: ((code: number, reason: string) => void) | undefined;
  let closeEvent: [number, string] | undefined;
  return {
    socket: {
      send,
      close,
      onMessage(callback) {
        onMessage = callback;
        for (const m of messages.splice(0)) callback(m);
      },
      onClose(callback) {
        onClose = callback;
        if (closeEvent) callback(...closeEvent);
      },
    },
    deliver(text) {
      if (onMessage) onMessage(text);
      else messages.push(text);
    },
    closed(code, reason) {
      closeEvent = [code, reason];
      onClose?.(code, reason);
    },
  };
}
