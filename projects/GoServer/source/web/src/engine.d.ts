// Globals from the N-Player Go Lab engine (static/engine.js), loaded by a classic <script>
// before this app. The engine is the rules reference and stays unchanged.
declare function makeGeom(n: number): any;
declare function newState(g: any, k: number, koOn: boolean): any;
declare function cloneState(s: any): any;
declare function stateKey(g: any, s: any): any;
declare function play(g: any, s: any, m: number): any;
declare function isLegal(g: any, s: any, m: number): boolean;
declare function isTerminal(g: any, s: any): boolean;
declare function scoreState(g: any, s: any, owners: boolean): any;
declare const RESIGN: number;
declare const TIMEOUT: number;

interface Window {
  webkitAudioContext?: typeof AudioContext;
  GameViewDebug?: any;
}
