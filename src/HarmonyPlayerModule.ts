import { requireOptionalNativeModule } from 'expo-modules-core';
import type { NativeModule } from 'expo';

import type { HarmonyPlayerEvents } from './HarmonyPlayer.types';

declare class HarmonyPlayerModule extends NativeModule<HarmonyPlayerEvents> {
  initialize(): Promise<void>;
  play(): void;
  pause(): void;
  stop(): void;
  seekTo(ms: number): void;
  setVolume(vol: number): void;
  openURL(url: string): Promise<void>;
  openFile(path: string): Promise<void>;
  openDeezerTrack(trackId: string, encUrl: string, contentLength: number, contentType: string): Promise<void>;
  preloadURL(url: string): Promise<void>;
  preloadFile(path: string): Promise<void>;
  preloadDeezerTrack(trackId: string, encUrl: string, contentLength: number, contentType: string): Promise<void>;
  getPositionMs(): number;
  getDurationMs(): number;
  getState(): string;
  updateNowPlaying(title: string, artist: string, album: string, artwork: string, duration: number): void;
  setHalveDuration(enabled: boolean): void;
  remux(inputPath: string, outputPath: string): Promise<void>;
}

export default requireOptionalNativeModule<HarmonyPlayerModule>('HarmonyPlayer');
