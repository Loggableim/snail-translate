/// Delivery status of a chat message.
enum MessageStatus {
  /// Message is queued locally, not yet sent to the relay.
  queued,

  /// Message has been sent to the relay but not yet acknowledged.
  sent,

  /// Message has been acknowledged as delivered by the relay.
  delivered,

  /// Message has been read by the recipient.
  read,
}
