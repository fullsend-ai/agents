# API Reference

## GET /orders/{id}

Returns a single order by id.

## POST /orders

Creates a new order. Applies any active discount before returning the total.

## Pricing

Discounts are expressed as whole-number percentages (0-100) and are applied
to the subtotal before tax.
