/// Домены российских сервисов, которые сидят не на `.ru` / `.рф` / `.su`.
///
/// Идут в bypass (direct) вместе с суффиксами при `new-routing-enabled`.
/// Пополнять осторожно: лишний домен = трафик мимо VPN с домашнего IP.
///
/// Формат для ядра: `domain:name` через запятую (см. SingboxRule.domains).
library;

/// Суффиксы и явные хосты для поля `domains` правила bypass.
const ruDirectDomainRule =
    'domain:.ru,'
    'domain:.su,'
    'domain:xn--p1ai,' // .рф
    'domain:vk.com,'
    'domain:vk.ru,'
    'domain:userapi.com,'
    'domain:vkuseraudio.net,'
    'domain:vkuservideo.net,'
    'domain:vkuserlive.net,'
    'domain:yandex.com,'
    'domain:yandex.net,'
    'domain:yandex.st,'
    'domain:yastatic.net,'
    'domain:ya.ru,'
    'domain:yandexcloud.net,'
    'domain:mail.ru,'
    'domain:imgsmail.ru,'
    'domain:mycdn.me,'
    'domain:okcdn.ru,'
    'domain:odnoklassniki.ru,'
    'domain:ok.ru,'
    'domain:wildberries.ru,'
    'domain:wbbasket.ru,'
    'domain:ozon.ru,'
    'domain:ozone.ru,'
    'domain:wb.ru,'
    'domain:tinkoff.ru,'
    'domain:tbank.ru,'
    'domain:sberbank.ru,'
    'domain:sber.ru,'
    'domain:gosuslugi.ru,'
    'domain:mos.ru,'
    'domain:nalog.ru,'
    'domain:cbr.ru,'
    'domain:rt.ru,'
    'domain:mts.ru,'
    'domain:megafon.ru,'
    'domain:beeline.ru,'
    'domain:tele2.ru,'
    'domain:dzen.ru,'
    'domain:rutube.ru,'
    'domain:ivitrina.tv,'
    'domain:kinopoisk.ru,'
    'domain:kp.cdn.yandex.net,'
    'domain:avito.ru,'
    'domain:avito.st,'
    'domain:hh.ru,'
    'domain:2gis.ru,'
    'domain:2gis.com,'
    'domain:max.ru';
