// Normalise AniList batch-artwork queries into a stable cache key.

function cacheKey(r) {
  var body = r.variables.request_body || "";

  if (body.indexOf("anime0:") < 0) {
    return body;
  }

  var isMal = /idMal:\s*\d/.test(body);
  var re = isMal ? /idMal:\s*(\d+)/g : /\bid:\s*(\d+)/g;

  var ids = [];
  var m;
  while ((m = re.exec(body)) !== null) {
    ids.push(parseInt(m[1], 10));
  }

  if (ids.length === 0) {
    return body;
  }

  ids.sort(function (a, b) {
    return a - b;
  });

  // Fold the selection-set shape into the key so two batches over the same
  // IDs but different requested fields cannot collide.
  var shape =
    (body.indexOf("bannerImage") >= 0 ? "b" : "-") +
    (body.indexOf("coverImage") >= 0 ? "c" : "-");

  return (
    "anilist-batch:" +
    (isMal ? "mal" : "al") +
    ":" +
    shape +
    ":" +
    ids.join(",")
  );
}

export default { cacheKey };
