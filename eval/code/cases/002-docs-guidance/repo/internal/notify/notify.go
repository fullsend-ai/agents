package notify

import "fmt"

// Service handles sending notifications to various channels.
type Service struct {
	sent []string
}

// NewService creates a notification service.
func NewService() *Service {
	return &Service{}
}

// Send delivers a message to the given channel.
func (s *Service) Send(channel, message string) error {
	if channel == "" {
		return fmt.Errorf("channel is required")
	}
	if message == "" {
		return fmt.Errorf("message is required")
	}
	s.sent = append(s.sent, fmt.Sprintf("%s: %s", channel, message))
	return nil
}

// SentCount returns the number of messages sent.
func (s *Service) SentCount() int {
	return len(s.sent)
}
