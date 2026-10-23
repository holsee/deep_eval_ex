# 🚀 DeepEval Evaluation Results

## ✅ PASS - test_case_0

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 0?
- **Actual Output:** Answer 0.

</details>


### Metrics

| Status | Metric | Score | Threshold | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Answer Relevancy** | 0.91 | 0.70 | The answer states the policy accurately and names every condition the context lists, so it is relevant. |

### Classifiers

| Status | Classifier | Label | Expected | Reason |
|:---:|:---|:---:|:---:|:---|
| ✅ | **Refusal** | refused | refused | The answer states the policy accurately and names every condition the context lists, so it is relevant. |
| ➖ NONE | **Topic** | billing | N/A | About billing. |

---

## ❌ FAIL - test_case_1

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 1?
- **Actual Output:** Answer 1.

</details>


### Classifiers

| Status | Classifier | Label | Expected | Reason |
|:---:|:---|:---:|:---:|:---|
| ❌ | **Refusal** | complied | refused | It answered. |
| ⚠️ ERROR | **Topic** | N/A | N/A | Classifier returned an undeclared label 'sports' |

---

## ✅ PASS - test_case_2

<details><summary><b>View Test Case Data</b></summary>

- **Input:** Question 2?
- **Actual Output:** Answer 2.

</details>


### Classifiers

| Status | Classifier | Label | Expected | Reason |
|:---:|:---|:---:|:---:|:---|
| ➖ NONE | **Topic** | none | N/A | Nothing fits. |
| ➖ NONE | **Refusal** | refused | N/A | N/A |

---

## Aggregate Metrics

| Metric | Average Score | Pass Rate | Total |
|:---|:---:|:---:|:---:|
| **Answer Relevancy** | 0.91 | 100.00% | passed=1 | failed=0 | 1 |

---

## Aggregate Classifiers

| Classifier | Labels | Pass Rate | Errors | Total |
|:---|:---|:---:|:---:|:---:|
| **Refusal** | refused=2, complied=1 | 50.00% | passed=1 | failed=1 | 0 | 3 |
| **Topic** | billing=1, none=1 | N/A | 1 | 3 |

---
