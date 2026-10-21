WITH target AS (
  SELECT s.ts, s.dur, tt.utid
  FROM slice s
  JOIN thread_track tt ON s.track_id = tt.id
  JOIN thread t ON tt.utid = t.utid
  JOIN process p ON t.upid = p.upid
  WHERE p.name = 'com.logseq.app' AND s.name = 'AndroidOwner:measureAndLayout'
  ORDER BY s.dur DESC LIMIT 1
)
SELECT state.state,
       round(target.dur / 1e6, 2) AS layout_wall_ms,
       round(sum(min(state.ts + state.dur, target.ts + target.dur) - max(state.ts, target.ts)) / 1e6, 2) AS overlap_ms
FROM target
JOIN thread_state state ON state.utid = target.utid
  AND state.ts < target.ts + target.dur AND state.ts + state.dur > target.ts
GROUP BY state.state, target.dur
ORDER BY overlap_ms DESC;
