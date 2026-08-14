#!/usr/bin/env python3
"""负载均衡定时轮换策略测试。"""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "lb-proxy.py"
SPEC = importlib.util.spec_from_file_location("lb_proxy", MODULE_PATH)
assert SPEC and SPEC.loader
lb_proxy = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lb_proxy)


class RotateStrategyTests(unittest.TestCase):
    def setUp(self):
        self.backends = [("10.64.0.2", 1080), ("10.64.1.2", 1080), ("10.64.2.2", 1080)]
        self.original_strategy = lb_proxy.LB_STRATEGY
        self.original_interval = lb_proxy.LB_ROTATE_INTERVAL_SECONDS
        self.original_started_at = lb_proxy._rotate_started_at
        self.original_slot = lb_proxy._rotate_slot
        self.original_target = lb_proxy._rotate_target
        self.original_backend = lb_proxy._rotate_backend
        self.original_backend_order = list(lb_proxy._rotate_backend_order)
        self.original_connection_state_file = lb_proxy.BACKEND_CONNECTION_STATE_FILE
        self.original_backend_connections = dict(lb_proxy._backend_connections)
        lb_proxy.LB_STRATEGY = "rotate"
        lb_proxy.LB_ROTATE_INTERVAL_SECONDS = 300
        lb_proxy._rotate_started_at = 1000.0
        lb_proxy._rotate_slot = 0
        lb_proxy._rotate_target = None
        lb_proxy._rotate_backend = None
        lb_proxy._rotate_backend_order = []
        lb_proxy._backend_connections = {}
        self.addCleanup(self.restore_globals)

    def restore_globals(self):
        lb_proxy.LB_STRATEGY = self.original_strategy
        lb_proxy.LB_ROTATE_INTERVAL_SECONDS = self.original_interval
        lb_proxy._rotate_started_at = self.original_started_at
        lb_proxy._rotate_slot = self.original_slot
        lb_proxy._rotate_target = self.original_target
        lb_proxy._rotate_backend = self.original_backend
        lb_proxy._rotate_backend_order = self.original_backend_order
        lb_proxy.BACKEND_CONNECTION_STATE_FILE = self.original_connection_state_file
        lb_proxy._backend_connections = self.original_backend_connections

    def test_rotate_uses_one_backend_for_the_entire_time_window(self):
        with patch.object(lb_proxy, "load_backends", return_value=self.backends):
            with patch.object(lb_proxy.time, "monotonic", return_value=1299.9):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.1", "session-a"), self.backends[0]
                )
            with patch.object(lb_proxy.time, "monotonic", return_value=1299.9):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.2", "session-b"), self.backends[0]
                )

    def test_rotate_switches_all_new_connections_at_the_next_window(self):
        with patch.object(lb_proxy, "load_backends", return_value=self.backends):
            with patch.object(lb_proxy.time, "monotonic", return_value=1300.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.1", "session-a"), self.backends[1]
                )
            with patch.object(lb_proxy.time, "monotonic", return_value=1600.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.2", "session-b"), self.backends[2]
                )
            with patch.object(lb_proxy.time, "monotonic", return_value=1900.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.3", "session-c"), self.backends[0]
                )

    def test_rotate_keeps_the_failover_target_during_a_rolling_restart(self):
        with patch.object(lb_proxy, "load_backends", return_value=self.backends):
            with patch.object(lb_proxy.time, "monotonic", return_value=1300.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.1", None), self.backends[1]
                )

        # 实例 1 被滚动重启摘流后，当前窗口只故障转移一次到实例 2。
        with patch.object(lb_proxy, "load_backends", return_value=[self.backends[0], self.backends[2]]):
            with patch.object(lb_proxy.time, "monotonic", return_value=1350.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.2", None), self.backends[2]
                )

        # 实例 1 恢复不会让当前窗口跳回，下一次常规轮换才切换。
        with patch.object(lb_proxy, "load_backends", return_value=self.backends):
            with patch.object(lb_proxy.time, "monotonic", return_value=1400.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.3", None), self.backends[2]
            )
            with patch.object(lb_proxy.time, "monotonic", return_value=1600.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.4", None), self.backends[2]
                )
            with patch.object(lb_proxy.time, "monotonic", return_value=1900.0):
                self.assertEqual(
                    lb_proxy.pick_backend("203.0.113.5", None), self.backends[0]
                )

    def test_rotate_interval_accepts_minutes_and_explicit_units(self):
        self.assertEqual(lb_proxy.parse_rotate_interval_seconds("5"), 300)
        self.assertEqual(lb_proxy.parse_rotate_interval_seconds("5m"), 300)
        self.assertEqual(lb_proxy.parse_rotate_interval_seconds("300s"), 300)
        self.assertEqual(lb_proxy.parse_rotate_interval_seconds("1h"), 3600)
        with self.assertRaises(ValueError):
            lb_proxy.parse_rotate_interval_seconds("0")

    def test_rendezvous_hash_is_stable_and_limits_remapping_on_add(self):
        old_backends = self.backends[:2]
        new_backend = self.backends[2]
        keys = [f"session-{index}" for index in range(500)]
        before = {
            key: lb_proxy.rendezvous_backend(key, old_backends) for key in keys
        }
        after = {
            key: lb_proxy.rendezvous_backend(key, self.backends) for key in keys
        }

        self.assertTrue(all(before[key] in old_backends for key in keys))
        # 新增实例时，发生迁移的会话只能迁移到新增实例，而不会在旧实例间回跳。
        self.assertTrue(
            all(after[key] == before[key] or after[key] == new_backend for key in keys)
        )
        self.assertGreater(sum(after[key] == new_backend for key in keys), 0)

    def test_rendezvous_hash_spreads_many_distinct_ids_evenly(self):
        backends = [
            ("10.64.0.2", 1080),
            ("10.64.1.2", 1080),
            ("10.64.2.2", 1080),
            ("10.64.3.2", 1080),
        ]
        counts = {backend: 0 for backend in backends}
        for index in range(4000):
            counts[lb_proxy.rendezvous_backend(f"session-{index}", backends)] += 1

        # 4,000 个离散 id 的期望为每实例 1,000；容许确定性哈希的正常统计波动。
        self.assertLess(max(counts.values()) - min(counts.values()), 180)

    def test_backend_connection_state_tracks_connections_for_drain(self):
        backend = self.backends[0]
        with tempfile.TemporaryDirectory() as temporary_directory:
            state_file = Path(temporary_directory) / "lb-connections.txt"
            lb_proxy.BACKEND_CONNECTION_STATE_FILE = str(state_file)

            lb_proxy.track_backend_connection(backend, 1)
            self.assertEqual(state_file.read_text(encoding="utf-8"), "10.64.0.2:1080\t1\n")

            lb_proxy.track_backend_connection(backend, -1)
            self.assertEqual(state_file.read_text(encoding="utf-8"), "")


if __name__ == "__main__":
    unittest.main()
