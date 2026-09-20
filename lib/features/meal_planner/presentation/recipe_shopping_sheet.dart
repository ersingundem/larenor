import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/home_session_controller.dart';
import '../../../shared/theme/typography.dart';
import '../../today/data/today_actions.dart';
import '../../today/domain/today_models.dart';
import '../data/recipe_shopping_handoff.dart';
import '../domain/recipe_shopping_draft.dart';

final recipeShoppingAuthoritySourceProvider =
    Provider.autoDispose<RecipeShoppingAuthoritySource?>((ref) {
      final home = ref.watch(homeSessionControllerProvider);
      return home == null ? null : HomeRecipeShoppingAuthoritySource(home);
    });

final class RecipeShoppingCopy {
  const RecipeShoppingCopy._(this.tr);
  final bool tr;
  static RecipeShoppingCopy of(BuildContext context) => RecipeShoppingCopy._(
    Localizations.localeOf(context).languageCode.toLowerCase() == 'tr',
  );

  String get title => tr ? 'Tarifi alışverişe ekle' : 'Add recipe to shopping';
  String get recipe => tr ? 'Tarif adı' : 'Recipe name';
  String get baseServings => tr ? 'Tarif porsiyonu' : 'Recipe servings';
  String get targetServings => tr ? 'Hedef porsiyon' : 'Target servings';
  String get ingredients => tr ? 'Malzemeler' : 'Ingredients';
  String get ingredientHint => tr
      ? 'Her satır: miktar birim malzeme\n200 g Mercimek\n2 adet Havuç'
      : 'One per line: quantity unit ingredient\n200 g Lentils\n2 pcs Carrots';
  String get units => tr
      ? 'Birimler: g, kg, ml, l, adet. En fazla 32 satır.'
      : 'Units: g, kg, ml, l, pcs. Up to 32 lines.';
  String get submit => tr ? 'Alışveriş listesine ekle' : 'Add to shopping list';
  String get working =>
      tr ? 'Ekleniyor ve doğrulanıyor…' : 'Adding and verifying…';
  String success(int count, String recipe, String list) => tr
      ? '$recipe tarifinden $count malzeme $list listesinde doğrulandı.'
      : '$count ingredients from $recipe verified in $list.';
  String get invalid => tr
      ? 'Porsiyonları ve “miktar birim malzeme” satırlarını kontrol edin.'
      : 'Check servings and each “quantity unit ingredient” line.';
  String get changed => tr
      ? 'Ev, hesap, oturum veya ekran değişti. Kalan öğeler gönderilmedi.'
      : 'Home, account, session or screen changed. Remaining items were not sent.';
  String get unavailable => tr
      ? 'Bu alışveriş listesi şu anda yazılabilir değil.'
      : 'This shopping list is not writable right now.';
}

class RecipeShoppingLaunchButton extends StatelessWidget {
  const RecipeShoppingLaunchButton({
    super.key,
    required this.list,
    required this.actions,
    required this.enabled,
  });

  final TodayTodoList list;
  final TodayActions actions;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final copy = RecipeShoppingCopy.of(context);
    return SizedBox(
      height: 48,
      child: CupertinoButton(
        key: ValueKey('recipe-launch-${list.entityId}'),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        onPressed: enabled
            ? () => Navigator.of(context).push<void>(
                CupertinoPageRoute(
                  fullscreenDialog: true,
                  builder: (_) =>
                      RecipeShoppingSheet(list: list, actions: actions),
                ),
              )
            : null,
        child: Text(copy.title),
      ),
    );
  }
}

class RecipeShoppingSheet extends ConsumerStatefulWidget {
  const RecipeShoppingSheet({
    super.key,
    required this.list,
    required this.actions,
  });

  final TodayTodoList list;
  final TodayActions actions;

  @override
  ConsumerState<RecipeShoppingSheet> createState() =>
      _RecipeShoppingSheetState();
}

class _RecipeShoppingSheetState extends ConsumerState<RecipeShoppingSheet>
    with WidgetsBindingObserver {
  final _title = TextEditingController();
  final _base = TextEditingController(text: '2');
  final _target = TextEditingController(text: '2');
  final _ingredients = TextEditingController();
  final _submitFocus = FocusNode(debugLabel: 'recipe-submit');
  ValueListenable<TickerModeData>? _ticker;
  bool _visible = true;
  bool _foreground = true;
  bool _busy = false;
  int _generation = 0;
  _RecipeStatus? _status;

  bool get _active =>
      mounted &&
      _visible &&
      _foreground &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ticker = TickerMode.getValuesNotifier(context);
    if (!identical(ticker, _ticker)) {
      _ticker?.removeListener(_visibilityChanged);
      _ticker = ticker;
      _visible = ticker.value.enabled;
      ticker.addListener(_visibilityChanged);
    }
  }

  void _visibilityChanged() {
    _visible = _ticker?.value.enabled ?? true;
    if (!_visible) _expire();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _foreground = false;
      _expire();
    } else {
      _foreground = true;
      if (mounted) setState(() {});
    }
  }

  void _expire() {
    _generation++;
    _busy = false;
    _status = null;
    if (mounted) setState(() {});
  }

  bool _current(int generation) => _active && generation == _generation;

  Future<void> _submit() async {
    if (_busy || !_active) return;
    final source = ref.read(recipeShoppingAuthoritySourceProvider);
    final authority = source == null
        ? null
        : RecipeShoppingAuthorityLease.capture(source);
    if (source == null || authority == null) {
      setState(() => _status = const _RecipeStatus('changed', false));
      return;
    }
    final copy = RecipeShoppingCopy.of(context);
    final locale = Localizations.localeOf(context).languageCode;
    final RecipeShoppingDraft draft;
    try {
      draft = RecipeShoppingDraft.parse(
        title: _title.text,
        baseServingsText: _base.text,
        targetServingsText: _target.text,
        ingredientLines: _ingredients.text,
      );
    } on RecipeShoppingException {
      setState(() => _status = const _RecipeStatus('invalid', false));
      return;
    }
    final generation = _generation;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final receipt = await RecipeShoppingHandoff().add(
        draft: draft,
        locale: locale,
        list: widget.list,
        actions: widget.actions,
        authority: authority,
        authoritySource: source,
        visible: () => _current(generation),
      );
      if (_current(generation)) {
        setState(
          () => _status = _RecipeStatus(
            copy.success(receipt.verifiedCount, draft.title, widget.list.title),
            true,
          ),
        );
      }
    } on RecipeShoppingException catch (error) {
      if (_current(generation)) {
        setState(
          () => _status = _RecipeStatus(
            error.code == 'list_unavailable' ? 'unavailable' : 'changed',
            false,
          ),
        );
      }
    } catch (_) {
      if (_current(generation)) {
        setState(() => _status = const _RecipeStatus('unavailable', false));
      }
    } finally {
      if (_current(generation)) setState(() => _busy = false);
    }
  }

  String _statusText(RecipeShoppingCopy copy) => switch (_status?.text) {
    'invalid' => copy.invalid,
    'changed' => copy.changed,
    'unavailable' => copy.unavailable,
    final String value => value,
    null => '',
  };

  Widget _field({
    required String label,
    required TextEditingController controller,
    required Key key,
    String? placeholder,
    TextInputType? keyboardType,
    TextInputAction? textInputAction,
    int minLines = 1,
    int maxLines = 1,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: AppText.headline),
      const SizedBox(height: 6),
      Semantics(
        textField: true,
        label: label,
        child: CupertinoTextField(
          key: key,
          controller: controller,
          enabled: !_busy,
          placeholder: placeholder,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          minLines: minLines,
          maxLines: maxLines,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final copy = RecipeShoppingCopy.of(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: Text(copy.title),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          child: const Icon(CupertinoIcons.xmark),
        ),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.all(20),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(widget.list.title, style: AppText.title2),
                    const SizedBox(height: 20),
                    _field(
                      label: copy.recipe,
                      controller: _title,
                      key: const ValueKey('recipe-title'),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    if (constraints.maxWidth >= 760 &&
                        MediaQuery.textScalerOf(context).scale(1) < 1.5)
                      Row(
                        children: [
                          Expanded(
                            child: _servingField(
                              copy.baseServings,
                              _base,
                              const ValueKey('recipe-base-servings'),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: _servingField(
                              copy.targetServings,
                              _target,
                              const ValueKey('recipe-target-servings'),
                            ),
                          ),
                        ],
                      )
                    else ...[
                      _servingField(
                        copy.baseServings,
                        _base,
                        const ValueKey('recipe-base-servings'),
                      ),
                      const SizedBox(height: 16),
                      _servingField(
                        copy.targetServings,
                        _target,
                        const ValueKey('recipe-target-servings'),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _field(
                      label: copy.ingredients,
                      controller: _ingredients,
                      key: const ValueKey('recipe-ingredients'),
                      placeholder: copy.ingredientHint,
                      keyboardType: TextInputType.multiline,
                      minLines: 4,
                      maxLines: 8,
                    ),
                    const SizedBox(height: 8),
                    Text(copy.units, style: AppText.footnote),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 48,
                      child: CupertinoButton.filled(
                        key: const ValueKey('recipe-submit'),
                        focusNode: _submitFocus,
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? Semantics(
                                liveRegion: true,
                                label: copy.working,
                                child: const CupertinoActivityIndicator(),
                              )
                            : Text(copy.submit),
                      ),
                    ),
                    if (_status != null) ...[
                      const SizedBox(height: 16),
                      Semantics(
                        key: const ValueKey('recipe-status'),
                        liveRegion: true,
                        child: Text(
                          _statusText(copy),
                          style: _status!.success
                              ? AppText.headline
                              : AppText.footnote,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _servingField(
    String label,
    TextEditingController controller,
    Key key,
  ) => _field(
    label: label,
    controller: controller,
    key: key,
    keyboardType: TextInputType.number,
    textInputAction: TextInputAction.next,
  );

  @override
  void dispose() {
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.removeListener(_visibilityChanged);
    _title.dispose();
    _base.dispose();
    _target.dispose();
    _ingredients.dispose();
    _submitFocus.dispose();
    super.dispose();
  }
}

final class _RecipeStatus {
  const _RecipeStatus(this.text, this.success);
  final String text;
  final bool success;
}
