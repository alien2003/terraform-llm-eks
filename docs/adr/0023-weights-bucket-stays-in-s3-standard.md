# 0023. The weights bucket stays in S3 Standard

Date: 2026-09-08

## Status

Accepted.

## Context

The weights bucket holds model weights: a small number of very large objects, written once, read in
full every time a GPU node starts cold. Large objects in S3 are where storage class choice usually
pays for itself, so the reflex is to add a lifecycle transition to S3 Standard-IA or to hand the
bucket to S3 Intelligent-Tiering and stop thinking about it.

Neither reflex survives the pricing, and they fail for different reasons.

S3 Standard-IA charges a per-GB retrieval fee. Every cold node start is a full retrieval of the
weights, so the retrieval fee is not an edge case here, it is the main event. Standard-IA also bills
a minimum storage duration of 30 days per object: an object written and deleted inside a cloud
window is billed for 30 days regardless, and a lifecycle rule that expires an object early is billed
for the remainder of the 30 days anyway. This project's unit of time is the cloud window, not the
month.

S3 Intelligent-Tiering is a different case, and none of the Standard-IA objections carry over to it.
AWS's own storage-class comparison gives Intelligent-Tiering no minimum storage duration, no minimum
billable object size, and explicitly no retrieval fees. What it charges instead is a monitoring and
automation fee per object, and objects under 128 KB are not monitored and not charged it. So a cold node
start would not pay per GB retrieved, and an object written and deleted inside one window would not be
billed for the rest of a month. Older write-ups that describe a 30-day minimum on this class are
describing how it used to bill.

The reason to leave it out is that it would buy nothing here. Its saving comes from moving an object
that has not been read for 30 consecutive days down to the Infrequent Access tier. The weights are a
handful of objects read in full in every window, so there is no long unread stretch for the automation
to act on, and the fee would pay for a mechanism that never fires.

## Decision

The weights bucket uses S3 Standard. No storage class transition appears in its lifecycle
configuration.

Its lifecycle rules do only cleanup: expire noncurrent versions, expire delete markers that have
nothing under them, and abort incomplete multipart uploads.

The abort rule is the one that earns its place. Uploading tens of gigabytes means multipart uploads,
a failed upload leaves its parts in the bucket, and those parts are billed as storage while being
invisible in the ordinary object listing.

The decision is reversible and cheap to revisit. If the weights end up sitting unread between windows
for longer than a month, the class to move to is Intelligent-Tiering rather than Standard-IA, precisely
because reading an object back out of it costs nothing per GB. Either way it is a three line change to
the lifecycle configuration.

## Consequences

Storage is billed at the Standard rate for the whole life of the project. That is the highest
per-GB-month rate of the classes considered here, and the lowest total cost of any of them given this
access pattern.

Nothing here protects against the larger cost, which is not storage at all but the data transfer path
out of the bucket. That belongs to the cluster stack and is written up in this stack's README under
"What it costs".

## Sources

- Understanding and managing Amazon S3 storage classes, on Standard-IA: "suitable for objects larger
  than 128 KB that you plan to store for at least 30 days [...] If you delete an object before the
  end of the 30-day minimum storage duration period, you are charged for 30 days":
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html>
- Expiring objects, on lifecycle rules and the minimum duration charge:
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/lifecycle-expire-general-considerations.html>
- Amazon S3 FAQs, on the 128 KB minimum object storage charge for Standard-IA:
  <https://aws.amazon.com/s3/faqs/>
- The same storage-class page, comparison table, on Intelligent-Tiering: minimum storage duration
  "None", minimum billable object size "None", and "Monitoring and automation fees per object apply. No
  retrieval fees. Objects less than 128KB are not monitored and always stored in the Frequent Access
  tier." The Infrequent Access tier is reached by 30 consecutive days without access:
  <https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html>
- The change that retired the 30-day minimum on Intelligent-Tiering, which is why older descriptions of
  this class disagree with the table above: "S3 Intelligent-Tiering now has no minimum storage duration
  period for all objects" and "Monitoring and automation charges are no longer collected for objects
  smaller than 128 KB":
  <https://aws.amazon.com/blogs/aws/amazon-s3-intelligent-tiering-further-automating-cost-savings-for-short-lived-and-small-objects/>
