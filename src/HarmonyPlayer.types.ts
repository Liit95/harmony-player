export type HarmonyPlaybackState = 'idle' | 'playing' | 'paused' | 'stopped' | 'error';

export type StateChangedEvent = { state: HarmonyPlaybackState };
export type ProgressEvent = { position: number; duration: number; buffered: number };
export type ErrorEvent = { message: string };
export type RemoteCommandEvent = { command: 'next' | 'previous' };

export type HarmonyPlayerEvents = {
  onStateChanged: (event: StateChangedEvent) => void;
  onProgress: (event: ProgressEvent) => void;
  onTrackEnded: () => void;
  onError: (event: ErrorEvent) => void;
  onRemoteCommand: (event: RemoteCommandEvent) => void;
  onPreloadReady: () => void;
};
