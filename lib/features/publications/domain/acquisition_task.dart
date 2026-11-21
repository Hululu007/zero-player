import 'publication.dart';

enum AcquisitionState {
  waiting('等待下载'),
  resolving('解析领取链接'),
  downloading('下载中'),
  paused('已暂停'),
  downloaded('文件已下载，待导入'),
  importing('校验及导入中'),
  complete('已入库可读'),
  failed('需要处理');

  const AcquisitionState(this.label);
  final String label;
}

typedef CandidateFailure = ({
  int candidate,
  PublicationProblem problem,
  DateTime at,
  DateTime? retryAt,
});

final class AcquisitionTask {
  const AcquisitionTask({
    required this.id,
    required this.edition,
    required this.candidates,
    required this.state,
    this.received = 0,
    this.total,
    this.selected = 0,
    this.generation = 0,
    this.failures = const [],
    this.problem,
    this.spaceShortfall,
    this.retryAt,
    this.result,
    this.retainedArchive = false,
  });

  final String id;
  final PublicationEdition edition;
  final List<AcquisitionCandidate> candidates;
  final AcquisitionState state;
  final int received, selected, generation;
  final int? total;
  final List<CandidateFailure> failures;
  final PublicationProblem? problem;
  final PublicationSpaceShortfall? spaceShortfall;
  final DateTime? retryAt;
  final String? result;
  final bool retainedArchive;

  AcquisitionCandidate get candidate => candidates[selected];
}
