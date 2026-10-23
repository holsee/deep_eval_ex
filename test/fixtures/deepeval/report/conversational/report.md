# 🚀 DeepEval Evaluation Results

## ❌ FAIL - conversational_test_case_0

<details><summary><b>View Test Case Data</b></summary>

- **User**: I want to change my flight.
- **Assistant**: Sure, which booking?
- **User**: ABC123

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Turn Relevancy** | 0.40 | 0.50 | One turn is off topic. |

---

## ✅ PASS - test_case_0

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 0?
- **Actual Output:** Answer 0.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Faithfulness** | 1.00 | 0.50 | No contradictions. |

---

## ✅ PASS - empty conversation

<details><summary><b>View Test Case Data</b></summary>


</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Turn Relevancy** | 1.00 | 0.50 | All relevant. |

---

## Aggregate Metrics

| Metric | Average Score | Pass Rate | Total |
|:---|:---:|:---:|:---:|
| **Turn Relevancy** | 0.70 | 50.00% | passed=1 | failed=1 | 2 |
| **Faithfulness** | 1.00 | 100.00% | passed=1 | failed=0 | 1 |

---
