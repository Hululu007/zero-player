import 'package:flutter/material.dart';

const readingIcon = Icons.menu_book_outlined;
const publicationReadingPath = '/publications';

const readingDestinations = [
  (publicationReadingPath, '图书', readingIcon),
  ('/reading', '网络小说', Icons.auto_stories_outlined),
  ('/comics', '网络漫画', Icons.collections_bookmark_outlined),
  ('/audiobooks', '网络听书', Icons.headphones_outlined),
];

bool isReadingDestination(String location) =>
    readingDestinations.any((destination) => destination.$1 == location);
