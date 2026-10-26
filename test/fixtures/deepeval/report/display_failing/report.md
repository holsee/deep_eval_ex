# 🚀 DeepEval Evaluation Results

## ✅ PASS - test_case_0

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 0?
- **Actual Output:** Answer 0.
- **Expected Output:** The policy allows refunds within 30 days.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Answer Relevancy** | 0.91 | 0.70 | The answer states the policy accurately and names every condition the context lists, so it is relevant. |
| ✅ | **Faithfulness** | 1.00 | 0.50 | No contradictions. |

---

## ❌ FAIL - refund question

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Can I get a refund on a used ticket?
- **Actual Output:** Yes, always.
No questions asked.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Answer Relevancy** | 0.33 | 0.70 | Off topic. |
| ❌ | **Faithfulness** | 0.25 | 0.50 | The answer contradicts the retrieval context on the refund window, which is 30 days. |

---

## ❌ FAIL - test_case_2

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 2?
- **Actual Output:** Answer 2.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Answer Relevancy** | 0.91 | 0.70 | The answer states the policy accurately and names every condition the context lists, so it is relevant. |
| ❌ | **Faithfulness** | 0.25 | 0.50 | The answer contradicts the retrieval context on the refund window, which is 30 days. |

---

## Aggregate Metrics

| Metric | Average Score | Pass Rate | Total |
|:---|:---:|:---:|:---:|
| **Answer Relevancy** | 0.72 | 66.67% | passed=2 | failed=1 | 3 |
| **Faithfulness** | 0.50 | 33.33% | passed=1 | failed=2 | 3 |

---
