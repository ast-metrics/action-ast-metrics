<?php

namespace Tests\Fixtures;

// Small fixture so the action has something to analyze in its own CI.
class Sample
{
    public function greet(string $name): string
    {
        if ($name === '') {
            return 'Hello, stranger';
        }

        return 'Hello, ' . $name;
    }
}
