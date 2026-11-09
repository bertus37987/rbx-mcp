#!/usr/bin/env node
// OBJ parsing + chunked upload preparation for the plugin's `editable_mesh` cmd.
//
// Contract (pinned with plugin): server parses the OBJ, then streams it in
// broker calls small enough to finish inside one lease (<90s):
//   editable_mesh { name, parent_path, verts:[[x,y,z]..], uvs:[[u,v]|null..],
//                   vbase:int, faces:[[i,j,k]..], batch:int, done:bool }
// - verts ride in ≤250-vert chunks, faces in ≤350-tri chunks (separate calls,
//   verts first, batch = 0-based call index, done=true only on the LAST call).
// - faces keep the OBJ's GLOBAL 1-based indices — the plugin accumulates verts
//   in send order and resolves face indices against that running array.
// - uvs are parallel to verts (null where the vertex had no vt).
// The plugin builds the EditableMesh→MeshPart on done and returns {path,...}.

import { readFileSync } from "node:fs";

// parseObj(text) → { verts:[[x,y,z]], faces:[[i,j,k]] (1-based), uvs:[[u,v]|null] }
// Handles: v (w ignored), vt (w ignored), vn (skipped), f as v | v/vt | v/vt/vn
// | v//vn, negative (relative) indices, n-gon fan triangulation on vertex 1.
export function parseObj(text) {
  const verts = [];
  const vtList = [];
  const faces = [];
  const uvs = []; // aligned with verts; first vt seen per vertex wins
  const fix = (idx, len) => (idx < 0 ? len + idx + 1 : idx); // -1 = last element
  for (const raw of String(text).split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const parts = line.split(/\s+/);
    const kind = parts[0];
    if (kind === "v") {
      verts.push([+parts[1] || 0, +parts[2] || 0, +parts[3] || 0]);
      uvs.push(null);
    } else if (kind === "vt") {
      vtList.push([+parts[1] || 0, +parts[2] || 0]);
    } else if (kind === "f") {
      const poly = []; // [{v, t}]
      for (const tok of parts.slice(1)) {
        const [vStr, tStr] = tok.split("/");
        const v = fix(parseInt(vStr, 10) || 0, verts.length);
        const t = tStr === undefined || tStr === "" ? 0 : fix(parseInt(tStr, 10) || 0, vtList.length);
        if (v < 1) continue;
        if (t > 0 && uvs[v - 1] === null) uvs[v - 1] = vtList[t - 1] || null;
        poly.push(v);
      }
      for (let i = 2; i < poly.length; i++) faces.push([poly[0], poly[i - 1], poly[i]]); // fan
    }
    // o, g, s, vn, usemtl, mtllib, l, p — ignored
  }
  return { verts, faces, uvs };
}

export function parseObjFile(path) {
  return parseObj(readFileSync(path, "utf8"));
}

// chunkMesh(mesh, vertBatch=250, faceBatch=350) →
//   { vertChunks: [{verts, uvs, base}], faceChunks: [[i,j,k]..] }
// base = 0-based JS index of the chunk's first vert (plugin-side faces use
// base+1..base+n as global 1-based indices — verts are sent in order).
export function chunkMesh(mesh, vertBatch = 250, faceBatch = 350) {
  const vertChunks = [];
  for (let i = 0; i < mesh.verts.length; i += vertBatch)
    vertChunks.push({ verts: mesh.verts.slice(i, i + vertBatch), uvs: (mesh.uvs || []).slice(i, i + vertBatch), base: i });
  const faceChunks = [];
  for (let i = 0; i < mesh.faces.length; i += faceBatch) faceChunks.push(mesh.faces.slice(i, i + faceBatch));
  return { vertChunks, faceChunks };
}
