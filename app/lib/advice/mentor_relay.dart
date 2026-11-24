// The AI Mentor (導師召喚券): AI singing tips asked through the Karaoke
// Battle relay instead of the singer's own API key. The relay holds the key
// and passes the same request as "Ask AI" to Claude; the app sends no key.
// It is not running yet: while the address is empty the ticket is locked.

/// The relay's address (empty: not open yet).
const kMentorRelayUrl = '';

/// The model the relay asks (the relay may pick its own).
const kMentorModel = 'claude-sonnet-5-5';

/// Whether the AI Mentor can be called.
bool get mentorAvailable => kMentorRelayUrl.isNotEmpty;
