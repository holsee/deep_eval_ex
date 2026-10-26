# 🚀 DeepEval Evaluation Results

## ✅ PASS - test exact match passes

<details><summary><b>View Test Case Data</b></summary>

- **Input:** 2 + 2?
- **Actual Output:** 4
- **Expected Output:** 4

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Exact Match** | 1.00 | 1.00 | The actual and expected outputs are exact matches. |

---

## ❌ FAIL - test exact match fails

<details><summary><b>View Test Case Data</b></summary>

- **Input:** 2 + 3?
- **Actual Output:** 6
- **Expected Output:** 5

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Exact Match** | 0.00 | 1.00 | The actual and expected outputs are different. |

---

## Aggregate Metrics

| Metric | Average Score | Pass Rate | Total |
|:---|:---:|:---:|:---:|
| **Exact Match** | 0.50 | 50.00% | passed=1 | failed=1 | 2 |

---
