# 🚀 DeepEval Evaluation Results

## ✅ PASS - test_case_0

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 0?
- **Actual Output:** Answer 0.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Tone** | 0.90 | 0.50 | N/A |
| ✅ | **Faithfulness** | 1.00 | 0.50 | No contradictions. |

---

## ✅ PASS - test_case_1

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 1?
- **Actual Output:** Answer 1.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Tone** | 0.10 | 0.50 | N/A |
| ✅ | **Faithfulness** | 1.00 | 0.50 | No contradictions. |

---

## ❌ FAIL - test_case_2

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 2?
- **Actual Output:** Answer 2.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Tone** | 0.20 | 0.50 | N/A |
| ❌ | **Faithfulness** | 0.25 | 0.50 | The answer contradicts the retrieval context on the refund window, which is 30 days. |

---

## Aggregate Metrics

| Metric | Average Score | Pass Rate | Total |
|:---|:---:|:---:|:---:|
| **Tone** | 0.40 | 33.33% | passed=1 (flaky=1) | failed=2 (flaky=1) | 3 |
| **Faithfulness** | 0.75 | 66.67% | passed=2 | failed=1 | 3 |

---
