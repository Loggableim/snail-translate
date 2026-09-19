// GENERATED from shared/dto/v1/messages.json. Do not edit by hand.
const int protocolVersion = 1;

enum ProtocolMessageType {
  auth,
  authOk,
  authError,
  chat,
  voice,
  edit,
  delete,
  signal,
  ping,
  chatHistory,
  deliveryAck,
  peerJoined,
  peerLeft,
  sessionEnd,
  subtitle,
  listenerJoined,
  listenerLeft,
  listenerKick,
  listenerKicked,
  error,
}
