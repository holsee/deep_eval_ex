# 🚀 DeepEval Evaluation Results

## ✅ PASS - case 1

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 0?
- **Actual Output:** Answer 0.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Faithfulness** | 1.00 | 0.50 | No contradictions. |

---

## ❌ FAIL - case 2

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 1?
- **Actual Output:** Answer 1.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Faithfulness** | 0.25 | 0.50 | The answer contradicts the retrieval context on the refund window, which is 30 days. |

---

## ✅ PASS - Case 10

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 1?
- **Actual Output:** Answer 1.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Faithfulness** | 1.00 | 0.50 | No contradictions. |

---

## Aggregate Metrics

| Metric | Average Score | Pass Rate | Total |
|:---|:---:|:---:|:---:|
| **Faithfulness** | 0.75 | 66.67% | passed=2 | failed=1 | 3 |

---
