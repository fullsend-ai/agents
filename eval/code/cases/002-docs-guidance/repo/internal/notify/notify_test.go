package notify

import "testing"

func TestSendSuccess(t *testing.T) {
	svc := NewService()
	err := svc.Send("email", "hello")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if svc.SentCount() != 1 {
		t.Fatalf("expected 1 sent, got %d", svc.SentCount())
	}
}

func TestSendEmptyChannel(t *testing.T) {
	svc := NewService()
	err := svc.Send("", "hello")
	if err == nil {
		t.Fatal("expected error for empty channel")
	}
}

func TestSendEmptyMessage(t *testing.T) {
	svc := NewService()
	err := svc.Send("email", "")
	if err == nil {
		t.Fatal("expected error for empty message")
	}
}
