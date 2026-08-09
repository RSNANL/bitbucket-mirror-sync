// @ts-check
import mirrorConfig from "../../config/mirrors.json" with { type: "json" };
import { createWorker } from "./handler.js";

export default createWorker(mirrorConfig);
